import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOSSL
@testable import ProxyLabCore

final class HTTP2ProtocolTests: XCTestCase {
    func testInterceptionCertificateNegotiatesHTTP2AndHTTP1() async throws {
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let context = try await authority.serverContext(for: "localhost")
        XCTAssertEqual(context.configuration.applicationProtocols, ["h2", "http/1.1"])
    }

    func testHTTP1OnlyContextDoesNotChangeInterceptionContextForSameHost() async throws {
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let http1 = try await authority.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
        let intercepted = try await authority.serverContext(for: "localhost")
        let http1Again = try await authority.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
        XCTAssertEqual(http1.configuration.applicationProtocols, ["http/1.1"])
        XCTAssertEqual(intercepted.configuration.applicationProtocols, ["h2", "http/1.1"])
        XCTAssertTrue(http1 === http1Again)
        XCTAssertFalse(http1 === intercepted)
    }

    func testConcurrentHTTP2StreamsThroughCONNECTAreCapturedWithClientSource() async throws {
        let fixture = try await HTTP2Fixture.start()
        do {
            let connection = try await fixture.connect(protocols: ["h2"])
            let multiplexer = try await connection.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil)
                .map { $0.sendableView }.get()
            let first = try await fixture.requestHTTP2(path: "/slow", connection: connection, multiplexer: multiplexer)
            let second = try await fixture.requestHTTP2(path: "/fast", connection: connection, multiplexer: multiplexer)
            let secondResponse = try await second.response.get()
            let firstResponse = try await first.response.get()
            XCTAssertEqual(firstResponse.status, 200)
            XCTAssertEqual(secondResponse.status, 200)
            XCTAssertEqual(String(decoding: firstResponse.body, as: UTF8.self), "/slow")
            XCTAssertEqual(String(decoding: secondResponse.body, as: UTF8.self), "/fast")
            XCTAssertEqual(firstResponse.version, .init(major: 2, minor: 0))
            XCTAssertEqual(secondResponse.version, .init(major: 2, minor: 0))
            let firstID = try await first.channel.getOption(HTTP2StreamChannelOptions.streamID).get()
            let secondID = try await second.channel.getOption(HTTP2StreamChannelOptions.streamID).get()
            XCTAssertNotEqual(firstID, secondID)
            let records = try await fixture.records(count: 2)
            XCTAssertEqual(Set(records.map(\.request.url)), Set([fixture.url("/slow"), fixture.url("/fast")]))
            XCTAssertTrue(records.allSatisfy { $0.requestHTTPVersion == "HTTP/2" })
            XCTAssertTrue(records.allSatisfy { $0.responseHTTPVersion == "HTTP/2" })
            XCTAssertTrue(records.allSatisfy { $0.clientAddress == "127.0.0.1" && $0.tlsIntercepted })
            XCTAssertTrue(records.allSatisfy { $0.error == nil })
            XCTAssertTrue(records.allSatisfy { $0.response?.header("Transfer-Encoding") == nil })
            let slow = try XCTUnwrap(records.first { $0.request.url.hasSuffix("/slow") })
            let fast = try XCTUnwrap(records.first { $0.request.url.hasSuffix("/fast") })
            XCTAssertLessThan(try XCTUnwrap(fast.endedAt), try XCTUnwrap(slow.endedAt))
            try await connection.close().get()
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    func testHTTP1NegotiationAndNoALPNFallbackRemainAvailable() async throws {
        let fixture = try await HTTP2Fixture.start(originProtocols: ["http/1.1"])
        do {
            for (index, protocols) in [["http/1.1"], []].enumerated() {
                let connection = try await fixture.connect(protocols: protocols)
                let promise = connection.eventLoop.makePromise(of: HTTP2FixtureResponse.self)
                let collector = HTTP2ResponseHandler(response: promise)
                try await connection.pipeline.addHTTPClientHandlers().get()
                try await connection.pipeline.addHandler(collector).get()
                collector.installTimeout(on: connection)
                let path = "/fallback-\(index)"
                connection.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: path,
                                        headers: ["Host": "localhost:\(fixture.origin.localAddress!.port!)"])), promise: nil)
                try await connection.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
                let response = try await promise.futureResult.get()
                XCTAssertEqual(response.status, 200)
                XCTAssertEqual(response.version, .http1_1)
                XCTAssertEqual(String(decoding: response.body, as: UTF8.self), path)
                try await connection.close().get()
            }
            let records = try await fixture.records(count: 2)
            XCTAssertEqual(records.count, 2)
            XCTAssertTrue(records.allSatisfy { $0.requestHTTPVersion == "HTTP/1.1" && $0.responseHTTPVersion == "HTTP/1.1" })
            XCTAssertTrue(records.allSatisfy { $0.error == nil })
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    func testHTTP2ClientCanForwardToHTTP1Origin() async throws {
        let fixture = try await HTTP2Fixture.start(originProtocols: ["http/1.1"])
        do {
            let connection = try await fixture.connect(protocols: ["h2"])
            let multiplexer = try await connection.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil)
                .map { $0.sendableView }.get()
            let request = try await fixture.requestHTTP2(path: "/http1-origin", connection: connection, multiplexer: multiplexer)
            let response = try await request.response.get()
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.version, .init(major: 2, minor: 0))
            XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "/http1-origin")
            let records = try await fixture.records(count: 1)
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.requestHTTPVersion, "HTTP/2")
            XCTAssertEqual(record.responseHTTPVersion, "HTTP/1.1")
            XCTAssertNil(record.error)
            try await connection.close().get()
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    func testHTTP2StreamingResponseDoesNotCaptureHTTP1ChunkedFraming() async throws {
        let fixture = try await HTTP2Fixture.start()
        do {
            let connection = try await fixture.connect(protocols: ["h2"])
            let multiplexer = try await connection.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil)
                .map { $0.sendableView }.get()
            let request = try await fixture.requestHTTP2(path: "/stream", connection: connection, multiplexer: multiplexer)
            let response = try await request.response.get()
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "/stream")
            let records = try await fixture.records(count: 1)
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.requestHTTPVersion, "HTTP/2")
            XCTAssertNil(record.response?.header("Transfer-Encoding"))
            XCTAssertNil(record.error)
            try await connection.close().get()
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    func testHTTP2ResponseTrailersReachClientAndCaptureForStreamingAndRewrittenResponses() async throws {
        let fixture = try await HTTP2Fixture.start()
        do {
            let connection = try await fixture.connect(protocols: ["h2"])
            let multiplexer = try await connection.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil)
                .map { $0.sendableView }.get()
            for rewritten in [false, true] {
                await fixture.proxy.setRules(rewritten ? [RewriteRule(name: "rewrite response", match: RuleMatch(host: "localhost"),
                    phase: .response, action: .replaceText(find: "grpc body", replace: "rewritten"))] : [])
                let request = try await fixture.requestHTTP2(path: "/grpc", connection: connection, multiplexer: multiplexer)
                let response = try await request.response.get()
                XCTAssertEqual(response.status, 200)
                XCTAssertEqual(String(decoding: response.body, as: UTF8.self), rewritten ? "rewritten" : "grpc body")
                XCTAssertEqual(response.trailers?.first(name: "grpc-status"), "0")
                XCTAssertEqual(response.trailers?.first(name: "grpc-message"), "OK")
            }
            let records = try await fixture.records(count: 2)
            XCTAssertEqual(records.count, 2)
            XCTAssertTrue(records.allSatisfy { $0.responseTrailers?.contains(HTTPHeader(name: "grpc-status", value: "0")) == true })
            XCTAssertTrue(records.allSatisfy { $0.responseTrailers?.contains(HTTPHeader(name: "grpc-message", value: "OK")) == true })
            XCTAssertTrue(records.allSatisfy { $0.error == nil })
            try await connection.close().get()
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }

    func testHTTP1ClientReceivesHTTP2TrailersWithChunkedFramingForStreamingAndRewrittenResponses() async throws {
        let fixture = try await HTTP2Fixture.start()
        do {
            for rewritten in [false, true] {
                await fixture.proxy.setRules(rewritten ? [RewriteRule(name: "rewrite response", match: RuleMatch(host: "localhost"),
                    phase: .response, action: .replaceText(find: "grpc body", replace: "rewritten"))] : [])
                let connection = try await fixture.connect(protocols: ["http/1.1"])
                let promise = connection.eventLoop.makePromise(of: HTTP2FixtureResponse.self)
                let collector = HTTP2ResponseHandler(response: promise)
                try await connection.pipeline.addHTTPClientHandlers().get()
                try await connection.pipeline.addHandler(collector).get()
                collector.installTimeout(on: connection)
                connection.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/grpc-known-length",
                    headers: ["Host": "localhost:\(fixture.origin.localAddress!.port!)"])), promise: nil)
                try await connection.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
                let response = try await promise.futureResult.get()
                XCTAssertEqual(String(decoding: response.body, as: UTF8.self), rewritten ? "rewritten" : "grpc body")
                XCTAssertEqual(response.trailers?.first(name: "grpc-status"), "0")
                try await connection.close().get()
            }
            let records = try await fixture.records(count: 2)
            XCTAssertEqual(records.count, 2)
            XCTAssertTrue(records.allSatisfy { $0.response?.header("Transfer-Encoding") == "chunked" })
            XCTAssertTrue(records.allSatisfy { $0.response?.header("Content-Length") == nil })
            XCTAssertTrue(records.allSatisfy { $0.responseTrailers?.contains(HTTPHeader(name: "grpc-status", value: "0")) == true })
            XCTAssertTrue(records.allSatisfy { $0.error == nil })
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }
}

private final class HTTP2Fixture: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let origin: Channel
    let proxy: ProxyEngine
    let store: SessionStore
    let directory: URL
    let clientTLS: TLSConfiguration
    let proxyPort: Int

    private init(group: MultiThreadedEventLoopGroup, origin: Channel, proxy: ProxyEngine, store: SessionStore,
                 directory: URL, clientTLS: TLSConfiguration, proxyPort: Int) {
        self.group = group
        self.origin = origin
        self.proxy = proxy
        self.store = store
        self.directory = directory
        self.clientTLS = clientTLS
        self.proxyPort = proxyPort
    }

    static func start(originProtocols: [String]? = nil) async throws -> HTTP2Fixture {
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let issuedContext = try await authority.serverContext(for: "localhost")
        var originTLS = issuedContext.configuration
        if let originProtocols { originTLS.applicationProtocols = originProtocols }
        let context = try NIOSSLContext(configuration: originTLS)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
            }.flatMap {
                channel.configureHTTP2SecureUpgrade(h2ChannelConfigurator: { connection in
                    connection.configureHTTP2Pipeline(mode: .server) { stream in
                        stream.eventLoop.makeCompletedFuture {
                            try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                            try stream.pipeline.syncOperations.addHandler(HTTP2OriginHandler())
                        }
                    }.map { _ in }
                }, http1ChannelConfigurator: { connection in
                    connection.pipeline.configureHTTPServerPipeline().flatMap {
                        connection.pipeline.addHandler(HTTP2OriginHandler())
                    }
                })
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(authority.rootCertificateDER), format: .der)])
        let proxy = ProxyEngine(store: store, upstreamTLSConfiguration: tls)
        await proxy.configureTLS(authority: authority)
        let port = try await proxy.start(port: 0)
        return HTTP2Fixture(group: group, origin: origin, proxy: proxy, store: store, directory: directory,
                            clientTLS: tls, proxyPort: port)
    }

    func url(_ path: String) -> String { "https://localhost:\(origin.localAddress!.port!)\(path)" }

    func connect(protocols: [String]) async throws -> Channel {
        let responsePromise = group.next().makePromise(of: String.self)
        let connectCollector = CONNECTResponseHandler(response: responsePromise)
        let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(3))
            .channelInitializer { $0.pipeline.addHandler(connectCollector) }.connect(host: "127.0.0.1", port: proxyPort).get()
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
            responsePromise.fail(HTTP2FixtureError.timeout)
            channel.close(promise: nil)
        }
        responsePromise.futureResult.whenComplete { _ in timeout.cancel() }
        try await channel.writeAndFlush(ByteBuffer(string: "CONNECT localhost:\(origin.localAddress!.port!) HTTP/1.1\r\nHost: localhost:\(origin.localAddress!.port!)\r\n\r\n")).get()
        let response = try await responsePromise.futureResult.get()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        try await channel.pipeline.removeHandler(connectCollector).get()
        var tls = clientTLS
        tls.applicationProtocols = protocols
        let context = try NIOSSLContext(configuration: tls)
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: "localhost"))
        }.get()
        return channel
    }

    func requestHTTP2(path: String, connection: Channel, multiplexer: HTTP2StreamMultiplexer.SendableView) async throws
        -> (channel: Channel, response: EventLoopFuture<HTTP2FixtureResponse>) {
        let promise = connection.eventLoop.makePromise(of: HTTP2FixtureResponse.self)
        let collector = HTTP2ResponseHandler(response: promise)
        let streamPromise = connection.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamPromise) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                try channel.pipeline.syncOperations.addHandler(collector)
            }
        }
        let stream = try await streamPromise.futureResult.get()
        collector.installTimeout(on: stream)
        let head = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .GET, uri: path,
                                   headers: ["Host": "localhost:\(origin.localAddress!.port!)"])
        stream.write(HTTPClientRequestPart.head(head), promise: nil)
        try await stream.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
        return (stream, promise.futureResult)
    }

    func records(count: Int) async throws -> [CapturedTransaction] {
        for _ in 0..<100 {
            let records = try await store.list()
            if records.count >= count { return records }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await store.list()
    }

    func stop() async {
        await proxy.stop()
        try? await origin.close().get()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum HTTP2FixtureError: Error { case timeout, disconnected }

private struct HTTP2FixtureResponse: Sendable {
    let status: Int
    let version: HTTPVersion
    let body: Data
    let trailers: HTTPHeaders?
}

private final class CONNECTResponseHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let response: EventLoopPromise<String>
    private var bytes = Data()
    private var completed = false
    init(response: EventLoopPromise<String>) { self.response = response }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        let buffer = unwrapInboundIn(data)
        bytes.append(contentsOf: buffer.readableBytesView)
        if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
            completed = true
            response.succeed(String(decoding: bytes, as: UTF8.self))
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed { completed = true; response.fail(error) }
        context.close(promise: nil)
    }
}

private final class HTTP2ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let response: EventLoopPromise<HTTP2FixtureResponse>
    private var head: HTTPResponseHead?
    private var bytes = Data()
    private var completed = false
    init(response: EventLoopPromise<HTTP2FixtureResponse>) { self.response = response }
    func installTimeout(on channel: Channel) {
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
            self.finish(.failure(HTTP2FixtureError.timeout))
            channel.close(promise: nil)
        }
        response.futureResult.whenComplete { _ in timeout.cancel() }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(let buffer): bytes.append(contentsOf: buffer.readableBytesView)
        case .end(let trailers):
            if let head { finish(.success(HTTP2FixtureResponse(status: Int(head.status.code), version: head.version, body: bytes,
                                                             trailers: trailers))) }
        }
    }
    private func finish(_ result: Result<HTTP2FixtureResponse, Error>) {
        guard !completed else { return }
        completed = true
        response.completeWith(result)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { finish(.failure(error)); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(HTTP2FixtureError.disconnected))
        context.fireChannelInactive()
    }
}

private final class HTTP2OriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private var head: HTTPRequestHead?
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end:
            guard let head else { return }
            self.head = nil
            let channel = context.channel
            let respond: @Sendable () -> Void = {
                let hasTrailers = head.uri == "/grpc" || head.uri == "/grpc-known-length"
                let body = hasTrailers ? "grpc body" : head.uri
                let headers: HTTPHeaders = head.uri == "/grpc-known-length" ? ["Content-Type": "text/plain", "Content-Length": String(body.utf8.count)] :
                    head.uri == "/grpc" ? ["Content-Type": "text/plain"] :
                    head.uri == "/stream" ? [:] : ["Content-Length": String(body.utf8.count)]
                channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: head.version, status: .ok,
                                      headers: headers)), promise: nil)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: body))), promise: nil)
                let trailers: HTTPHeaders? = hasTrailers ? ["grpc-status": "0", "grpc-message": "OK"] : nil
                channel.writeAndFlush(HTTPServerResponsePart.end(trailers), promise: nil)
            }
            if head.uri == "/slow" { channel.eventLoop.scheduleTask(in: .milliseconds(75), respond) }
            else { respond() }
        }
    }
}
