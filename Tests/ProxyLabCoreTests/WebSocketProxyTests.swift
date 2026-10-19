import Foundation
import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
@testable import ProxyLabCore

final class WebSocketProxyTests: XCTestCase {
    // Accepting downstream before upstream negotiation, remasking incorrectly, or capturing fragments
    // separately breaks this real local wire fixture.
    func testLocalWebSocketUpgradeForwardsSubprotocolMaskedFragmentsAndControlFrames() async throws {
        try await exerciseUpgrade(secure: false)
    }

    func testLocalSecureWebSocketUpgradeUsesTrustedTLSAndPreservesHostnameRouting() async throws {
        try await exerciseUpgrade(secure: true)
    }

    func testExcludedWebSocketStillForwardsAndStoresNoHandshakeOrMessages() async throws {
        try await exerciseUpgrade(secure: false, excluded: true)
    }

    func testUpstreamMessagesArrivingWithHandshakeAreBufferedUntilClientUpgrade() async throws {
        try await exerciseUpgrade(secure: false, greeting: true)
    }

    func testRevokingClientClosesBothWebSocketPeers() async throws {
        try await exerciseUpgrade(secure: false, revoke: true)
    }

    func testRejectedUpstreamHandshakePreservesStatusAndBodyWithoutAttemptingHTTPFallback() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(WebSocketFixtureReject()) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let engine = ProxyEngine(store: store)
        let port = try await engine.start(port: 0)
        let bytes = WebSocketFixtureBytes()
        let client = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(WebSocketFixtureCollector(bytes: bytes)) }
            .connect(host: "127.0.0.1", port: port).get()
        let request = "GET ws://127.0.0.1:\(originPort)/reject HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try await client.writeAndFlush(ByteBuffer(string: request)).get()
        for _ in 0..<300 where client.isActive { try await Task.sleep(for: .milliseconds(10)) }
        let response = String(data: bytes.value, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("403 Forbidden"), response)
        XCTAssertTrue(response.contains("access denied"), response)
        XCTAssertFalse(response.contains("101 Switching Protocols"), response)
        let sessions = try await store.list()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.response?.status, 403)
        try? await client.close().get()
        await engine.stop()
        try await origin.close().get()
        try await group.shutdownGracefully()
    }

    private func exerciseUpgrade(secure: Bool, excluded: Bool = false, revoke: Bool = false, greeting: Bool = false) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let frames = WebSocketFixtureFrames()
        let ca = try CertificateAuthority(persistentDirectory: nil)
        let context = secure ? try await ca.serverContext(for: "ws.fixture.test") : nil
        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                let tls = channel.eventLoop.makeCompletedFuture {
                    if greeting { try channel.pipeline.syncOperations.addHandler(WebSocketFixtureCoalescingWriter()) }
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context)) }
                }
                return tls.flatMap {
                    let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, head in
                        frames.recordHandshake(head)
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders([("Sec-WebSocket-Protocol", "fixture.v1"), ("X-Fixture", "accepted")]))
                    }, upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(WebSocketFixtureEcho(frames: frames)).flatMap {
                            if greeting { return channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: "ready"))) }
                            return channel.eventLoop.makeSucceededFuture(())
                        }
                    })
                    return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(ca.rootCertificatePEM.utf8)))
        let engine = ProxyEngine(store: store, upstreamTLSConfiguration: tls,
                                 connectAddressOverrides: ["ws.fixture.test": "127.0.0.1"])
        if excluded { await engine.setCapturePolicy(CapturePolicy(exclude: [CaptureRule(match: RuleMatch(host: "ws.fixture.test"))])) }
        let proxyPort = try await engine.start(port: 0)
        let output = WebSocketFixtureBytes()
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(WebSocketFixtureCollector(bytes: output)) }
            .connect(host: "127.0.0.1", port: proxyPort).get()
        let scheme = secure ? "wss" : "ws"
        let request = "GET \(scheme)://ws.fixture.test:\(originPort)/socket?q=1 HTTP/1.1\r\nHost: ws.fixture.test:\(originPort)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: fixture.v1, fixture.v2\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
        try await client.writeAndFlush(ByteBuffer(string: request)).get()
        for _ in 0..<300 where !output.value.contains(Data("\r\n\r\n".utf8)) { try await Task.sleep(for: .milliseconds(10)) }
        let headerData = output.value.range(of: Data("\r\n\r\n".utf8)).map { output.value.prefix($0.upperBound) } ?? output.value
        let handshake = String(data: headerData, encoding: .utf8) ?? ""
        XCTAssertTrue(handshake.contains("101 Switching Protocols"), handshake)
        XCTAssertTrue(handshake.lowercased().contains("sec-websocket-protocol: fixture.v1"), handshake)
        XCTAssertTrue(handshake.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), handshake)
        XCTAssertFalse(handshake.lowercased().contains("permessage-deflate"), handshake)
        XCTAssertEqual(frames.handshake?.uri, "/socket?q=1")
        XCTAssertEqual(frames.handshake?.headers.first(name: "Host"), "ws.fixture.test:\(originPort)")
        XCTAssertNil(frames.handshake?.headers.first(name: "Sec-WebSocket-Extensions"))
        // Independent RFC 6455 fixture: masked "hel", then "lo", ping "p", binary [0,255].
        try await client.writeAndFlush(ByteBuffer(bytes: [0x01,0x83,1,2,3,4,0x69,0x67,0x6F,
                                                        0x80,0x82,5,6,7,8,0x69,0x69,
                                                        0x89,0x81,1,2,3,4,0x71,
                                                        0x82,0x82,1,2,3,4,1,0xFD])).get()
        for _ in 0..<300 where frames.value.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(frames.value.count, 4)
        XCTAssertTrue(frames.value.allSatisfy { $0.maskKey != nil })
        XCTAssertEqual(frames.value.first?.unmaskedData.getString(at: 0, length: 3), "hel")
        let messageStore = try WebSocketMessageStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        var transactions: [CapturedTransaction] = []
        var messages: [WebSocketMessage] = []
        for _ in 0..<300 {
            transactions = try await store.list()
            if let id = transactions.first?.id { messages = try await messageStore.list(transactionID: id) }
            if messages.count >= (greeting ? 7 : 6) || excluded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if excluded {
            XCTAssertTrue(transactions.isEmpty)
            XCTAssertTrue(messages.isEmpty)
        } else {
        XCTAssertEqual(transactions.first?.response?.status, 101)
        XCTAssertEqual(transactions.first?.request.url, "\(scheme)://ws.fixture.test:\(originPort)/socket?q=1")
        XCTAssertEqual(messages.filter { $0.opcode == .text }.map(\.decodedText), greeting ? ["ready", "hello", "hello"] : ["hello", "hello"])
        XCTAssertTrue(messages.contains { $0.opcode == .ping && $0.direction == .clientToServer && $0.decodedText == "p" })
        XCTAssertTrue(messages.contains { $0.opcode == .pong && $0.direction == .serverToClient && $0.payload == Data([0x70]) })
        XCTAssertEqual(messages.filter { $0.opcode == .binary }.map(\.payload), [Data([0,255]), Data([0,255])])
        }
        if let range = output.value.range(of: Data("\r\n\r\n".utf8)) {
            let wire = output.value.dropFirst(range.upperBound + (greeting ? 7 : 0))
            XCTAssertTrue(wire.starts(with: [0x01,0x03,0x68,0x65,0x6C,0x80,0x02,0x6C,0x6F]), "Downstream frames must be unmasked and retain fragmentation")
        }
        if revoke { await engine.setDeviceAccess(.denied, address: "127.0.0.1") }
        else { try await client.writeAndFlush(ByteBuffer(bytes: [0x88,0x82,1,2,3,4,0x02,0xEA])).get() } // close 1000
        for _ in 0..<200 where client.isActive { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(client.isActive)
        for _ in 0..<200 where !frames.closed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(frames.closed, "Upstream must close when the client is revoked or closed")
        try? await client.close().get()
        await engine.stop()
        try await origin.close().get()
        try await group.shutdownGracefully()
    }
}

private final class WebSocketFixtureBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    var value: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
}
private final class WebSocketFixtureFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [WebSocketFrame] = []
    private var head: HTTPRequestHead?
    private var isClosed = false
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }
    func recordClosed() { lock.lock(); defer { lock.unlock() }; isClosed = true }
    var value: [WebSocketFrame] { lock.lock(); defer { lock.unlock() }; return frames }
    var handshake: HTTPRequestHead? { lock.lock(); defer { lock.unlock() }; return head }
    func record(_ frame: WebSocketFrame) { lock.lock(); defer { lock.unlock() }; frames.append(frame) }
    func recordHandshake(_ head: HTTPRequestHead) { lock.lock(); defer { lock.unlock() }; self.head = head }
}
private final class WebSocketFixtureCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let bytes: WebSocketFixtureBytes
    init(bytes: WebSocketFixtureBytes) { self.bytes = bytes }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bytes.append(Data(buffer.readableBytesView))
    }
}
private final class WebSocketFixtureEcho: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let frames: WebSocketFixtureFrames
    init(frames: WebSocketFixtureFrames) { self.frames = frames }
    func channelInactive(context: ChannelHandlerContext) { frames.recordClosed(); context.fireChannelInactive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        frames.record(frame)
        let reply = WebSocketFrame(fin: frame.fin, opcode: frame.opcode == .ping ? .pong : frame.opcode, data: frame.unmaskedData)
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
    }
}

private final class WebSocketFixtureReject: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        let body = "access denied"
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .forbidden,
            headers: HTTPHeaders([("Content-Length", "13"), ("Content-Type", "text/plain")])))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

/// Holds the origin upgrade response until its first WebSocket frame, then emits a single
/// byte buffer. This exercises bytes already inside the upstream HTTP decoder at removal.
private final class WebSocketFixtureCoalescingWriter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = IOData
    typealias OutboundOut = ByteBuffer
    private var pending = ByteBuffer()
    private var flushes = 0
    private var released = false

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if released { context.write(data, promise: promise); return }
        switch unwrapOutboundIn(data) {
        case .byteBuffer(var buffer): pending.writeBuffer(&buffer)
        case .fileRegion: preconditionFailure("The fixture handshake must be in memory")
        }
        // The upgrader awaits its HTTP flush before it can create the WebSocket frame.
        promise?.succeed(())
    }
    func flush(context: ChannelHandlerContext) {
        if released { context.flush(); return }
        flushes += 1
        guard flushes == 2 else { return }
        released = true
        context.writeAndFlush(wrapOutboundOut(pending), promise: nil)
        pending = ByteBuffer()
    }
}
