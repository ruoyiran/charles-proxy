import Foundation
import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import Darwin
@testable import ProxyLabCore

final class ProxyEngineTests: XCTestCase {
    func testHTTPSCapturesBothHeadersAndBodiesIncludingCompressedResponse() async throws {
        let upstreamCA = try CertificateAuthority(persistentDirectory: nil)
        let upstreamContext = try await upstreamCA.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: upstreamContext)) }
                catch { return channel.eventLoop.makeFailedFuture(error) }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CompressedJSONOriginHandler())
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootURL = directory.appendingPathComponent("proxy-root.pem")
        let proxyCA = try CertificateAuthority(persistentDirectory: nil)
        try proxyCA.rootCertificatePEM.write(to: rootURL, atomically: true, encoding: .utf8)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(upstreamCA.rootCertificateDER), format: .der)])
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store, upstreamTLSConfiguration: tls)
        await proxy.configureTLS(authority: proxyCA, includeHosts: ["localhost"])
        let port = try await proxy.start(port: 0)
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--max-time", "10",
                             "--proxy", "http://127.0.0.1:\(port)", "--cacert", rootURL.path,
                             "-H", "Content-Type: application/json", "-H", "X-Inspection-Test: request-header",
                             "--data-binary", "{\"sent\":true}", "https://localhost:\(originPort)/inspect"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let received = output.fileHandleForReading.readDataToEndOfFile()
        await proxy.stop()
        try await origin.close().get()
        try await group.shutdownGracefully()
        let records = try await store.list()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(record.tlsIntercepted)
        XCTAssertEqual(record.request.header("X-Inspection-Test"), "request-header")
        XCTAssertEqual(record.request.body, Data("{\"sent\":true}".utf8))
        XCTAssertEqual(record.response?.header("X-Inspection-Test"), "response-header")
        XCTAssertEqual(record.response?.headers.filter { $0.name.lowercased() == "set-cookie" }.count, 2)
        XCTAssertEqual(record.response?.body, received)
        XCTAssertEqual(try BodyContent.decode(received, contentEncoding: record.response?.header("Content-Encoding")),
                       Data("{\"message\":\"captured response\",\"ok\":true}".utf8))
    }

    func testForwardsHTTPAndRecordsCompletedTransaction() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let proxyPort = try await proxy.start(port: 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                             "http://127.0.0.1:\(originPort)/fixture"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let body = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(body, "hello from origin")
        let transactions = try await store.list()
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.request.method, "GET")
        XCTAssertEqual(transactions.first?.response?.status, 200)
    }

    func testConnectCreatesOpaqueBidirectionalTunnel() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { $0.pipeline.addHandler(FixtureEchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let proxyPort = try await proxy.start(port: 0)

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(proxyPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let connectRequest = "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n"
        _ = connectRequest.withCString { Darwin.send(socketFD, $0, strlen($0), 0) }
        var response = Data()
        var byte: UInt8 = 0
        while !response.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)) && response.count < 1_024 {
            let count = Darwin.recv(socketFD, &byte, 1, 0)
            guard count == 1 else { break }
            response.append(byte)
        }
        XCTAssertTrue(String(data: response, encoding: .utf8)?.contains("200") == true)
        _ = "ping".withCString { Darwin.send(socketFD, $0, 4, 0) }
        var reply = [UInt8](repeating: 0, count: 4)
        let count = Darwin.recv(socketFD, &reply, reply.count, 0)
        XCTAssertEqual(count, 4)
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "ping")
        _ = Darwin.close(socketFD)
        await proxy.stop()
        let transactions = try await store.list()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()
        XCTAssertEqual(transactions.first?.request.method, "CONNECT")
        XCTAssertEqual(transactions.first?.response?.status, 200)
        XCTAssertEqual(transactions.first?.tlsIntercepted, false)
    }

    func testOpaqueConnectCompletesTLSHandshakeToLocalOrigin() async throws {
        let upstreamCA = try CertificateAuthority(persistentDirectory: nil)
        let upstreamContext = try await upstreamCA.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: upstreamContext)) }
                catch { return channel.eventLoop.makeFailedFuture(error) }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootURL = directory.appendingPathComponent("upstream-root.pem")
        try upstreamCA.rootCertificatePEM.write(to: rootURL, atomically: true, encoding: .utf8)
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let proxyPort = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                             "--cacert", rootURL.path, "https://localhost:\(originPort)/fixture"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let body = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()

        XCTAssertEqual(process.terminationStatus, 0, stderr ?? "")
        XCTAssertEqual(body, "hello from origin")
        let transactions = try await store.list()
        XCTAssertEqual(transactions.first?.request.method, "CONNECT")
        XCTAssertEqual(transactions.first?.tlsIntercepted, false)
    }

    func testOpaqueConnectCanUseResolvedAddressWhileKeepingOriginalTLSHost() async throws {
        let upstreamCA = try CertificateAuthority(persistentDirectory: nil)
        let upstreamContext = try await upstreamCA.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: upstreamContext)) }
                catch { return channel.eventLoop.makeFailedFuture(error) }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootURL = directory.appendingPathComponent("upstream-root.pem")
        try upstreamCA.rootCertificatePEM.write(to: rootURL, atomically: true, encoding: .utf8)
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store, connectAddressOverrides: ["localhost": "127.0.0.1"])
        let proxyPort = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                             "--cacert", rootURL.path, "https://localhost:\(originPort)/fixture"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let body = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()

        XCTAssertEqual(process.terminationStatus, 0, stderr ?? "")
        XCTAssertEqual(body, "hello from origin")
    }

    func testGoogleStyleCONNECTUsesTrustedDNSWhenSystemDNSReturnsPrivateAddress() async throws {
        let upstreamCA = try CertificateAuthority(persistentDirectory: nil)
        let upstreamContext = try await upstreamCA.serverContext(for: "www.google.com.hk", applicationProtocols: ["http/1.1"])
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: upstreamContext)) }
                catch { return channel.eventLoop.makeFailedFuture(error) }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootURL = directory.appendingPathComponent("upstream-root.pem")
        try upstreamCA.rootCertificatePEM.write(to: rootURL, atomically: true, encoding: .utf8)
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let resolver = StaticTestResolver(address: "127.0.0.1")
        let proxy = ProxyEngine(store: store, trustedResolver: resolver,
                                trustedDNSHosts: ["www.google.com.hk"])
        let proxyPort = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                             "--cacert", rootURL.path, "https://www.google.com.hk:\(originPort)/fixture"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let body = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()

        XCTAssertEqual(process.terminationStatus, 0, stderr ?? "")
        XCTAssertEqual(body, "hello from origin")
        let queried = await resolver.queriedHosts
        XCTAssertEqual(queried, ["www.google.com.hk"])
    }

    func testTrustedDNSResolverGetsPublicAddressForGoogle() async throws {
        guard ProcessInfo.processInfo.environment["PROXYLAB_LIVE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set PROXYLAB_LIVE_NETWORK_TESTS=1 to exercise the public DNS endpoint")
        }
        let resolver = GoogleHTTPSDNSResolver()
        let address: String
        do {
            address = try await resolver.resolve(host: "www.google.com.hk")
        } catch {
            await resolver.shutdown()
            throw error
        }
        await resolver.shutdown()
        var parsed = in_addr()
        XCTAssertEqual(inet_pton(AF_INET, address, &parsed), 1)
        XCTAssertFalse(address.hasPrefix("10."))
    }

    func testLiveGooglePageSucceedsThroughTrustedDNSProxy() async throws {
        guard ProcessInfo.processInfo.environment["PROXYLAB_LIVE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set PROXYLAB_LIVE_NETWORK_TESTS=1 to exercise Google through ProxyLab")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store, trustedResolver: GoogleHTTPSDNSResolver(),
                                trustedDNSHosts: ["www.google.com.hk"])
        let port = try await proxy.start(port: 0)
        for attempt in 1...3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["--silent", "--show-error", "--noproxy", "", "--max-time", "20",
                                 "--proxy", "http://127.0.0.1:\(port)", "--output", "/dev/null",
                                 "--write-out", "%{http_code}", "https://www.google.com.hk/"]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            let status = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, "Attempt \(attempt): \(stderr)")
            XCTAssertEqual(status, "200", "Attempt \(attempt): \(stderr)")
        }
        await proxy.stop()
    }

    func testTrustedDNSCanRouteInterceptedHTTPSUpstream() async throws {
        let upstreamCA = try CertificateAuthority(persistentDirectory: nil)
        let upstreamContext = try await upstreamCA.serverContext(for: "www.google.com.hk", applicationProtocols: ["http/1.1"])
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: upstreamContext)) }
                catch { return channel.eventLoop.makeFailedFuture(error) }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootURL = directory.appendingPathComponent("proxy-root.pem")
        let proxyCA = try CertificateAuthority(persistentDirectory: nil)
        try proxyCA.rootCertificatePEM.write(to: rootURL, atomically: true, encoding: .utf8)
        var upstreamTLS = TLSConfiguration.makeClientConfiguration()
        upstreamTLS.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(upstreamCA.rootCertificateDER), format: .der)])
        let resolver = StaticTestResolver(address: "127.0.0.1")
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store, upstreamTLSConfiguration: upstreamTLS,
                                trustedResolver: resolver, trustedDNSHosts: ["www.google.com.hk"])
        await proxy.configureTLS(authority: proxyCA, includeHosts: ["www.google.com.hk"])
        let proxyPort = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                             "--cacert", rootURL.path, "https://www.google.com.hk:\(originPort)/fixture"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let body = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()
        XCTAssertEqual(process.terminationStatus, 0, stderr ?? "")
        XCTAssertEqual(body, "hello from origin")
        let queried = await resolver.queriedHosts
        XCTAssertEqual(queried, ["www.google.com.hk"])
    }

    func testSelectedConnectHostIsDecryptedAndRecorded() async throws {
        let upstreamCA = try CertificateAuthority(persistentDirectory: nil)
        let upstreamContext = try await upstreamCA.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: upstreamContext)) }
                catch { return channel.eventLoop.makeFailedFuture(error) }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let proxyCA = try CertificateAuthority(persistentDirectory: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootURL = directory.appendingPathComponent("proxy-root.pem")
        try proxyCA.rootCertificatePEM.write(to: rootURL, atomically: true, encoding: .utf8)
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        var upstreamTLS = TLSConfiguration.makeClientConfiguration()
        upstreamTLS.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(upstreamCA.rootCertificateDER), format: .der)])
        let proxy = ProxyEngine(store: store, upstreamTLSConfiguration: upstreamTLS)
        await proxy.configureTLS(authority: proxyCA, includeHosts: ["localhost"])
        let proxyPort = try await proxy.start(port: 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                             "--cacert", rootURL.path, "https://localhost:\(originPort)/fixture"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let body = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()

        XCTAssertEqual(process.terminationStatus, 0, stderr ?? "")
        XCTAssertEqual(body, "hello from origin")
        let transactions = try await store.list()
        XCTAssertEqual(transactions.first?.tlsIntercepted, true)
        XCTAssertEqual(transactions.first?.request.url, "https://localhost:\(originPort)/fixture")
    }

    func testRequestBreakpointCanAbortBeforeUpstreamFetch() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = BreakpointCenter()
        await center.setRules([BreakpointRule(match: RuleMatch(host: "127.0.0.1"), phase: .request)])
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store, breakpointCenter: center)
        let port = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--noproxy", "", "--max-time", "5", "--proxy", "http://127.0.0.1:\(port)",
                             "--output", "/dev/null", "--write-out", "%{http_code}", "http://127.0.0.1:\(originPort)/fixture"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        var pending: PendingBreakpoint?
        for _ in 0..<200 {
            pending = await center.pending().first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let pending { await center.resolve(id: pending.id, decision: .abort) }
        for _ in 0..<600 where process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { process.terminate(); XCTFail("curl did not exit") }
        let status = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()

        XCTAssertNotNil(pending)
        XCTAssertEqual(status, "502")
    }

    func testLargeUploadReachesOriginWhileCaptureIsBounded() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CountingBodyHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = Data(repeating: 65, count: 11 * 1_024 * 1_024)
        let uploadURL = directory.appendingPathComponent("upload.bin")
        try upload.write(to: uploadURL)
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let port = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)",
                             "--data-binary", "@\(uploadURL.path)", "http://127.0.0.1:\(originPort)/upload"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let body = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(body, String(upload.count))
        let transactions = try await store.list()
        XCTAssertEqual(transactions.first?.request.body.count, 10 * 1_024 * 1_024)
        XCTAssertEqual(transactions.first?.requestBodyTruncated, true)
    }

    func testResponseStartsBeforeUpstreamFinishesStreaming() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(SlowStreamingOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let port = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)",
                             "--write-out", "\n%{time_starttransfer} %{time_total}", "http://127.0.0.1:\(originPort)/stream"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()
        let lines = text.split(separator: "\n")
        let timings = lines.last?.split(separator: " ").compactMap { Double($0) } ?? []
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("firstsecond"))
        XCTAssertEqual(timings.count, 2)
        if timings.count == 2 {
            XCTAssertLessThan(timings[0], 0.75)
            XCTAssertGreaterThan(timings[1], 1.0)
        }
    }

    func testRecordingToggleControlsPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let transaction = CapturedTransaction(request: ProxyRequest(method: "GET", url: "http://example.com/"))
        await proxy.setRecordingEnabled(false)
        await proxy.save(transaction)
        let whileOff = try await store.list()
        await proxy.setRecordingEnabled(true)
        await proxy.save(transaction)
        let whileOn = try await store.list()
        await proxy.stop()

        XCTAssertTrue(whileOff.isEmpty)
        XCTAssertEqual(whileOn.count, 1)
    }

    func testResponseBodyRuleRequestsIdentityEncodingFromUpstream() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        await proxy.setRules([RewriteRule(name: "replace", match: RuleMatch(host: "example.com"),
                                         phase: .response, action: .replaceText(find: "old", replace: "new"))])
        let request = ProxyRequest(method: "GET", url: "https://example.com/a",
                                   headers: [HTTPHeader(name: "Accept-Encoding", value: "gzip, br")])
        let prepared = await proxy.prepare(request)
        await proxy.stop()
        XCTAssertEqual(prepared.header("Accept-Encoding"), "identity")
    }

    func testRejectsForwardRequestToItsOwnListener() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let port = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--max-time", "3",
                             "--proxy", "http://127.0.0.1:\(port)", "--output", "/dev/null",
                             "--write-out", "%{http_code}", "http://127.0.0.1:\(port)/loop"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        for _ in 0..<400 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate() }
        let status = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        XCTAssertEqual(status, "502")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testPipelinedRequestsReturnResponsesInOriginalOrder() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(DelayedPathOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        let proxyPort = try await proxy.start(port: 0)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(proxyPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let requests = "GET http://127.0.0.1:\(originPort)/slow HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n" +
                       "GET http://127.0.0.1:\(originPort)/fast HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n"
        _ = requests.withCString { Darwin.send(socketFD, $0, strlen($0), 0) }
        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while received.count < 8192 {
            let count = Darwin.recv(socketFD, &bytes, bytes.count, 0)
            if count <= 0 { break }
            received.append(contentsOf: bytes.prefix(count))
            if String(decoding: received, as: UTF8.self).contains("slow-body") &&
               String(decoding: received, as: UTF8.self).contains("fast-body") { break }
        }
        _ = Darwin.close(socketFD)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()
        let text = String(decoding: received, as: UTF8.self)
        let slow = try XCTUnwrap(text.range(of: "slow-body"))
        let fast = try XCTUnwrap(text.range(of: "fast-body"))
        XCTAssertLessThan(slow.lowerBound, fast.lowerBound)
    }

    func testVeryLargeResponseStillPausesAtResponseBreakpoint() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(LargeBodyOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let center = BreakpointCenter()
        await center.setRules([BreakpointRule(match: RuleMatch(host: "127.0.0.1"), phase: .response)])
        let proxy = ProxyEngine(store: store, breakpointCenter: center)
        let port = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--max-time", "6", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)",
                             "--output", "/dev/null", "--write-out", "%{http_code}", "http://127.0.0.1:\(originPort)/large"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        var pending: PendingBreakpoint?
        for _ in 0..<400 {
            pending = await center.pending().first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let pending { await center.resolve(id: pending.id, decision: .abort) }
        for _ in 0..<600 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate() }
        let status = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.response?.body.count, 10 * 1_024 * 1_024)
        XCTAssertEqual(status, "502")
    }

    func testVeryLargeResponseCancelPreservesEntireBody() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: originGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(LargeBodyOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = try XCTUnwrap(origin.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let center = BreakpointCenter()
        await center.setRules([BreakpointRule(match: RuleMatch(host: "127.0.0.1"), phase: .response)])
        let proxy = ProxyEngine(store: store, breakpointCenter: center)
        let port = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--max-time", "10", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)",
                             "--output", "/dev/null", "--write-out", "%{size_download}",
                             "http://127.0.0.1:\(originPort)/large"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        var pending: PendingBreakpoint?
        for _ in 0..<400 {
            pending = await center.pending().first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let pending { await center.resolve(id: pending.id, decision: .cancel) }
        for _ in 0..<1_000 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate() }
        let size = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        await proxy.stop()
        try await origin.close().get()
        try await originGroup.shutdownGracefully()
        XCTAssertNotNil(pending)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(size, "11534336")
    }
}

private final class FixtureOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .end = unwrapInboundIn(data) {
            let body = "hello from origin"
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(body.utf8.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private final class CompressedJSONOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        let bytes = Data(base64Encoded: "H4sIAAAAAAACE6tWyk0tLk5MT1WyUkpOLCgpLUpNUShKLS7IzytOVdJRys9WsiopKk2tBQAd+Z4BKQAAAA==")!
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Encoding", value: "gzip")
        headers.add(name: "Content-Length", value: String(bytes.count))
        headers.add(name: "X-Inspection-Test", value: "response-header")
        headers.add(name: "Set-Cookie", value: "first=1")
        headers.add(name: "Set-Cookie", value: "second=2")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: bytes)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private final class FixtureEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
    }
}

private final class CountingBodyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var count = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: count = 0
        case .body(let buffer): count += buffer.readableBytes
        case .end:
            let body = String(count)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(body.utf8.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private final class SlowStreamingOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .end = unwrapInboundIn(data) {
            var headers = HTTPHeaders()
            headers.add(name: "Transfer-Encoding", value: "chunked")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "first")))), promise: nil)
            let channel = context.channel
            channel.eventLoop.scheduleTask(in: .milliseconds(1_200)) {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "second"))), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            }
        }
    }
}

private final class DelayedPathOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var path = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): path = head.uri
        case .body: break
        case .end:
            let body = path.contains("slow") ? "slow-body" : "fast-body"
            let channel = context.channel
            let send: @Sendable () -> Void = {
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: String(body.utf8.count))
                channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)), promise: nil)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: body))), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            }
            if body == "slow-body" { channel.eventLoop.scheduleTask(in: .milliseconds(200), send) }
            else { send() }
        }
    }
}

private final class LargeBodyOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .end = unwrapInboundIn(data) {
            let body = ByteBuffer(repeating: 65, count: 11 * 1_024 * 1_024)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(body.readableBytes))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private actor StaticTestResolver: TrustedHostResolving {
    let address: String
    private(set) var queriedHosts: [String] = []

    init(address: String) { self.address = address }

    func resolve(host: String) async throws -> String {
        queriedHosts.append(host)
        return address
    }
}
