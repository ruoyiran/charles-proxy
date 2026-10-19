import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
@testable import ProxyLabCore

final class MobileConnectionTests: XCTestCase {
    func testMobileToggleKeepsExistingLocalConnectionWorking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = ProxyEngine(store: try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path))
        await proxy.configureTLS(authority: try CertificateAuthority(persistentDirectory: nil))
        let port = try await proxy.start(port: 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = MobileResponseCollector()
        let channel = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: port).get()
        try await channel.writeAndFlush(ByteBuffer(string: "GET /setup HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")).get()
        try await Task.sleep(for: .milliseconds(30))
        try await proxy.setMobileConnectionsEnabled(true)
        try await proxy.setMobileConnectionsEnabled(false)
        try await channel.writeAndFlush(ByteBuffer(string: "GET /setup HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n")).get()
        try await channel.closeFuture.get()
        try await group.shutdownGracefully()
        await proxy.stop()
        let text = String(decoding: collector.bytes, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 200").count - 1, 2)
    }

    func testLANAdmissionCertificateDownloadAndRevocationWithRealConnections() async throws {
        guard let ip = LANAddress.available().first?.address else { throw XCTSkip("No LAN IPv4 interface is available") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let proxy = ProxyEngine(store: store)
        await proxy.configureTLS(authority: authority)
        let port = try await proxy.start(port: 0)
        try await proxy.setMobileConnectionsEnabled(true)
        let request = "GET /root-ca.cer HTTP/1.1\r\nHost: \(ip):\(port)\r\nConnection: close\r\n\r\n"
        let denied = try await exchange(ip: ip, port: port, request: request)
        XCTAssertTrue(String(decoding: denied, as: UTF8.self).hasPrefix("HTTP/1.1 403"))
        let pending = await proxy.mobileAccess.listDevices()
        XCTAssertEqual(pending.first?.address, ip)
        XCTAssertEqual(pending.first?.access, .pending)
        await proxy.setDeviceAccess(.allowed, address: ip)
        let allowed = try await exchange(ip: ip, port: port, request: request)
        XCTAssertTrue(String(decoding: allowed.prefix(32), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        let headerEnd = try XCTUnwrap(allowed.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertEqual(Data(allowed[headerEnd.upperBound...]), authority.rootCertificateDER)
        let persistentGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let persistent = try await ClientBootstrap(group: persistentGroup).connect(host: ip, port: port).get()
        // Make sure this connection has completed admission before revoking it.
        try await persistent.writeAndFlush(ByteBuffer(string: "GET /setup HTTP/1.1\r\nHost: \(ip):\(port)\r\n\r\n")).get()
        try await Task.sleep(for: .milliseconds(30))
        await proxy.setDeviceAccess(.denied, address: ip)
        try await persistent.closeFuture.get()
        try await persistentGroup.shutdownGracefully()
        let revoked = try await exchange(ip: ip, port: port, request: request)
        XCTAssertTrue(String(decoding: revoked, as: UTF8.self).hasPrefix("HTTP/1.1 403"))
        try await proxy.setMobileConnectionsEnabled(false)
        let devices = await proxy.mobileAccess.listDevices()
        XCTAssertTrue(devices.isEmpty)
        await proxy.stop()
    }

    func testHTTPAndHTTPSCaptureKeepClientSource() async throws {
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let context = try await authority.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context)) }
            catch { return channel.eventLoop.makeFailedFuture(error) }
            return channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(MobileFixtureHandler()) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(authority.rootCertificateDER), format: .der)])
        let proxy = ProxyEngine(store: store, upstreamTLSConfiguration: tls)
        await proxy.configureTLS(authority: authority)
        let port = try await proxy.start(port: 0)
        let root = directory.appendingPathComponent("root.pem")
        try authority.rootCertificatePEM.write(to: root, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)",
                             "--cacert", root.path, "--max-time", "5", "--output", "/dev/null", "https://localhost:\(origin.localAddress!.port!)/source"]
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        await proxy.stop()
        try await origin.close().get()
        try await group.shutdownGracefully()
        let records = try await store.list()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(records.first?.clientAddress, "127.0.0.1")
        XCTAssertTrue(records.first?.tlsIntercepted == true)
        let summaries = try await store.listSummaries(clientAddress: "127.0.0.1")
        XCTAssertEqual(summaries.count, 1)
        let other = try await store.listSummaries(clientAddress: "192.168.1.25")
        XCTAssertTrue(other.isEmpty)
        let imported = try HARCodec.decode(HARCodec.encode(records))
        XCTAssertEqual(imported.first?.clientAddress, "127.0.0.1")
    }

    func testOldSessionDocumentsDecodeWithoutDeviceMetadata() throws {
        let record = CapturedTransaction(request: ProxyRequest(method: "GET", url: "https://example.com"))
        let data = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "clientAddress")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CapturedTransaction.self, from: oldData)
        XCTAssertNil(decoded.clientAddress)
        XCTAssertEqual(decoded.request.url, record.request.url)
    }

    private func exchange(ip: String, port: Int, request: String) async throws -> Data {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = MobileResponseCollector()
        let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(3))
            .channelInitializer { $0.pipeline.addHandler(collector) }.connect(host: ip, port: port).get()
        try await channel.writeAndFlush(ByteBuffer(string: request)).get()
        try await channel.closeFuture.get()
        try await group.shutdownGracefully()
        return collector.bytes
    }
}

private final class MobileResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var bytes = Data()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let value = buffer.readBytes(length: buffer.readableBytes) { bytes.append(contentsOf: value) }
    }
}

private final class MobileFixtureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .end = unwrapInboundIn(data) {
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok,
                                                                 headers: ["Content-Length": "2"]))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "ok")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
