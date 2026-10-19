import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOWebSocket

/// RFC 6455 upgrades over HTTP/1.1; ordinary requests retain the standard HTTP proxy path.
enum WebSocketProxy {
    static let maximumFrameBytes = 4 * 1_024 * 1_024

    static func configureHTTP1(channel: Channel, engine: ProxyEngine,
                               tunnelAuthority: ProxyAuthority? = nil, tlsIntercepted: Bool = false) -> EventLoopFuture<Void> {
        let state = WebSocketUpgradeState()
        let http = ProxyHTTPHandler(engine: engine, tunnelAuthority: tunnelAuthority, tlsIntercepted: tlsIntercepted)
        let rejection = WebSocketRejectionHandler(state: state, engine: engine)
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: maximumFrameBytes, automaticErrorHandling: false,
            shouldUpgrade: { client, head in
                let promise = client.eventLoop.makePromise(of: HTTPHeaders?.self)
                let task = Task {
                    var transaction = CapturedTransaction(request: request(head, tunnelAuthority: tunnelAuthority),
                        tlsIntercepted: tlsIntercepted, clientAddress: client.remoteAddress?.ipAddress,
                        requestHTTPVersion: "HTTP/1.1", responseHTTPVersion: "HTTP/1.1")
                    do {
                        let result = try await negotiate(head: head, transaction: transaction, client: client, engine: engine)
                        transaction.response = result.response
                        let transport = WebSocketTransport(engine: engine, transaction: transaction, client: client, upstream: result.channel)
                        _ = await engine.beginWebSocket(transaction)
                        try Task.checkCancellation()
                        guard await engine.canForward(client), result.channel.isActive else { throw CancellationError() }
                        try await client.eventLoop.submit {
                            state.transport = transport
                            state.upstreamRelay = result.relay
                            promise.succeed(result.headers)
                        }.get()
                    } catch {
                        let response = (error as? WebSocketUpgradeFailure)?.response ?? ProxyResponse(status: 502, headers: [HTTPHeader(name: "Content-Type", value: "text/plain; charset=utf-8")], body: Data("WebSocket upstream upgrade failed.".utf8))
                        transaction.response = response
                        transaction.error = String(describing: error)
                        transaction.endedAt = Date()
                        await engine.save(transaction)
                        client.eventLoop.execute {
                            state.rejection = response
                            promise.succeed(nil)
                        }
                    }
                }
                state.task = task
                client.closeFuture.whenComplete { _ in task.cancel() }
                return promise.futureResult
            }, upgradePipelineHandler: { client, _ in
                guard let transport = state.transport, let upstreamRelay = state.upstreamRelay else {
                    return client.eventLoop.makeFailedFuture(WebSocketCaptureError.invalidFrame)
                }
                let clientRelay = WebSocketRelayHandler(direction: .clientToServer)
                return client.pipeline.addHandler(clientRelay).map {
                    clientRelay.activate(peer: transport.upstream, transport: transport)
                    transport.upstream.eventLoop.execute { upstreamRelay.activate(peer: client, transport: transport) }
                }
            })
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { context in
            context.pipeline.removeHandler(http, promise: nil)
            context.pipeline.removeHandler(rejection, promise: nil)
        }), withErrorHandling: true).flatMap {
            channel.pipeline.addHandlers(rejection, http)
        }
    }

    private static func request(_ head: HTTPRequestHead, tunnelAuthority: ProxyAuthority?) -> ProxyRequest {
        var url = head.uri
        if !["ws://", "wss://", "http://", "https://"].contains(where: url.lowercased().hasPrefix) {
            let host = tunnelAuthority.map { authority($0.host, port: $0.port) } ?? head.headers.first(name: "Host") ?? ""
            url = "\(tunnelAuthority == nil ? "ws" : "wss")://\(host)\(url.hasPrefix("/") ? "" : "/")\(url)"
        } else if url.lowercased().hasPrefix("https://") { url = "wss://" + url.dropFirst(8) }
        else if url.lowercased().hasPrefix("http://") { url = "ws://" + url.dropFirst(7) }
        return ProxyRequest(method: head.method.rawValue, url: url, headers: head.headers.map { HTTPHeader(name: $0.name, value: $0.value) })
    }

    private static func authority(_ host: String, port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    private static func negotiate(head: HTTPRequestHead, transaction: CapturedTransaction, client: Channel,
                                  engine: ProxyEngine) async throws -> WebSocketUpstreamResult {
        guard head.method == .GET, let key = head.headers.first(name: "Sec-WebSocket-Key") else { throw WebSocketCaptureError.invalidFrame }
        var outgoing = transaction.request
        if outgoing.url.hasPrefix("wss://") { outgoing.url = "https://" + outgoing.url.dropFirst(6) }
        else if outgoing.url.hasPrefix("ws://") { outgoing.url = "http://" + outgoing.url.dropFirst(5) }
        outgoing = await engine.prepare(outgoing, allowBodyChanges: false)
        guard let url = URL(string: outgoing.url), let host = url.host,
              let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme) else { throw ProxyRequestError.invalidURL }
        let secure = scheme == "https" || scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        let upstream = try await engine.connect(ProxyAuthority(host: host, port: port), clientChannel: client)
        client.closeFuture.whenComplete { _ in upstream.close(promise: nil) }
        do {
            try Task.checkCancellation()
            if secure {
                let configuration = await engine.webSocketTLSConfiguration()
                let context = try NIOSSLContext(configuration: configuration)
                try await upstream.eventLoop.submit {
                    try upstream.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host))
                }.get()
            }
            let handshake = WebSocketUpstreamHandshake(channel: upstream)
            let relay = WebSocketRelayHandler(direction: .serverToClient)
            let responseHandler = WebSocketUpstreamResponseHandler(handshake: handshake)
            let protocols = head.headers[canonicalForm: "Sec-WebSocket-Protocol"]
            let upgrader = NIOWebSocketClientUpgrader(requestKey: key, maxFrameSize: maximumFrameBytes,
                automaticErrorHandling: false, upgradePipelineHandler: { channel, response in
                    let selected = response.headers[canonicalForm: "Sec-WebSocket-Protocol"]
                    guard response.headers[canonicalForm: "Connection"].contains(where: { $0.lowercased() == "upgrade" }),
                          response.headers["Sec-WebSocket-Extensions"].isEmpty,
                          selected.count <= 1, selected.isEmpty || protocols.contains(selected[0]) else {
                        handshake.fail(WebSocketCaptureError.invalidFrame)
                        channel.close(promise: nil)
                        return channel.eventLoop.makeFailedFuture(WebSocketCaptureError.invalidFrame)
                    }
                    return channel.pipeline.addHandler(relay).map {
                        handshake.succeed(WebSocketUpstreamResult(channel: channel, relay: relay, response: ProxyResponse(status: 101,
                            headers: response.headers.map { HTTPHeader(name: $0.name, value: $0.value) }),
                            headers: HTTPHeaders(response.headers.filter { !ProxyEngine.isHopByHop($0.name) && $0.name.lowercased() != "sec-websocket-accept" })))
                    }
                })
            try await upstream.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, withClientUpgrade: (upgraders: [upgrader], completionHandler: { context in
                context.pipeline.removeHandler(responseHandler, promise: nil)
            })).get()
            try await upstream.pipeline.addHandler(responseHandler).get()
            var headers = HTTPHeaders()
            for header in outgoing.headers where !ProxyEngine.isHopByHop(header.name) && !["host", "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "content-length"].contains(header.name.lowercased()) {
                headers.add(name: header.name, value: header.value)
            }
            headers.replaceOrAdd(name: "Host", value: authority(host, port: port))
            var path = url.path.isEmpty ? "/" : url.path
            // URLComponents retains escaping and an empty query exactly as supplied by the client.
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
                if let query = components.percentEncodedQuery { path += "?" + query }
            }
            upstream.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)), promise: nil)
            try await upstream.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
            let result = try await handshake.promise.futureResult.get()
            try Task.checkCancellation()
            guard await engine.canForward(client) else { throw CancellationError() }
            return result
        } catch {
            try? await upstream.close().get()
            throw error
        }
    }
}

private final class WebSocketUpgradeState: @unchecked Sendable {
    var task: Task<Void, Never>?
    var transport: WebSocketTransport?
    var upstreamRelay: WebSocketRelayHandler?
    var rejection: ProxyResponse?
}
private struct WebSocketUpstreamResult: Sendable {
    let channel: Channel
    let relay: WebSocketRelayHandler
    let response: ProxyResponse
    let headers: HTTPHeaders
}
private struct WebSocketUpgradeFailure: Error { let response: ProxyResponse }

private final class WebSocketUpstreamHandshake: @unchecked Sendable {
    let promise: EventLoopPromise<WebSocketUpstreamResult>
    private let channel: Channel
    private var completed = false
    init(channel: Channel) {
        self.channel = channel
        promise = channel.eventLoop.makePromise(of: WebSocketUpstreamResult.self)
        channel.eventLoop.scheduleTask(in: .seconds(10)) { self.fail(ChannelError.connectTimeout(.seconds(10))) }
    }
    func succeed(_ result: WebSocketUpstreamResult) {
        guard !completed else { return }; completed = true; promise.succeed(result)
    }
    func fail(_ error: Error) {
        guard !completed else { return }; completed = true; promise.fail(error)
    }
}
private final class WebSocketUpstreamResponseHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let handshake: WebSocketUpstreamHandshake
    private var response: ProxyResponse?
    init(handshake: WebSocketUpstreamHandshake) { self.handshake = handshake }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): response = ProxyResponse(status: Int(head.status.code), headers: head.headers.map { HTTPHeader(name: $0.name, value: $0.value) })
        case .body(let buffer):
            if var response {
                guard response.body.count + buffer.readableBytes <= 1_048_576 else { handshake.fail(WebSocketCaptureError.messageTooLarge); context.close(promise: nil); return }
                response.body.append(contentsOf: buffer.readableBytesView)
                self.response = response
            }
        case .end:
            if let response { handshake.fail(WebSocketUpgradeFailure(response: response)) }
            else { handshake.fail(WebSocketCaptureError.invalidFrame) }
            context.close(promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { handshake.fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { handshake.fail(ChannelError.eof); context.fireChannelInactive() }
}

private final class WebSocketRejectionHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let state: WebSocketUpgradeState
    let engine: ProxyEngine
    init(state: WebSocketUpgradeState, engine: ProxyEngine) { self.state = state; self.engine = engine }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // NIO signals a declined upgrade before replaying the HTTP request. Our recorded refusal
        // is written by channelRead once the buffered request end arrives.
        if state.rejection == nil { context.fireErrorCaught(error) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard var response = state.rejection else { context.fireChannelRead(data); return }
        if case .end = unwrapInboundIn(data) {
            response.headers.removeAll { ProxyEngine.isHopByHop($0.name) || $0.name.lowercased() == "content-length" }
            response.setHeader("Content-Length", value: String(response.body.count))
            response.setHeader("Connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.status), headers: HTTPHeaders(response.headers.map { ($0.name, $0.value) })))), promise: nil)
            if !response.body.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: response.body)))), promise: nil) }
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}

private final class WebSocketTransport: @unchecked Sendable {
    let engine: ProxyEngine
    let client: Channel
    let upstream: Channel
    private let lock = NSLock()
    private var transaction: CapturedTransaction
    private var closed = false
    private var closeDirections: Set<WebSocketDirection> = []
    init(engine: ProxyEngine, transaction: CapturedTransaction, client: Channel, upstream: Channel) {
        self.engine = engine; self.transaction = transaction; self.client = client; self.upstream = upstream
    }
    func save(_ message: WebSocketMessage) async { await engine.saveWebSocketMessage(message, transactionID: transaction.id) }
    func sawClose(_ direction: WebSocketDirection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        closeDirections.insert(direction)
        return closeDirections.count == 2
    }
    func finish(error: String? = nil) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        transaction.endedAt = Date()
        if let error { transaction.error = error }
        let final = transaction
        lock.unlock()
        client.close(promise: nil)
        upstream.close(promise: nil)
        Task { await engine.finishWebSocket(final) }
    }
}

/// One read batch is bounded; each side awaits the peer's flushed write and durable capture before reading more.
private final class WebSocketRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    let direction: WebSocketDirection
    private var assembler: WebSocketMessageAssembler
    private var queue: [(WebSocketFrame, WebSocketMessage?)] = []
    private var queueBytes = 0
    private var source: Channel?
    private var peer: Channel?
    private var transport: WebSocketTransport?
    private var writing = false
    private var task: Task<Void, Never>?
    private var closeTimeout: Scheduled<Void>?
    private var closeReceived = false
    init(direction: WebSocketDirection) { self.direction = direction; assembler = WebSocketMessageAssembler(direction: direction) }
    func handlerAdded(context: ChannelHandlerContext) {
        source = context.channel
        let channel = context.channel
        channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in channel.close(promise: nil) }
    }
    func activate(peer: Channel, transport: WebSocketTransport) { self.peer = peer; self.transport = transport; drain() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let incoming = unwrapInboundIn(data)
        guard !closeReceived, (incoming.maskKey != nil) == (direction == .clientToServer) else { fail("Invalid WebSocket masking or frame after close."); return }
        do {
            let message = try assembler.receive(incoming)
            let frame = WebSocketFrame(fin: incoming.fin, opcode: incoming.opcode,
                maskKey: direction == .clientToServer ? WebSocketMaskingKey([UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255)]) : nil,
                data: incoming.unmaskedData)
            guard queue.count < 256, queueBytes + frame.length <= WebSocketProxy.maximumFrameBytes else { fail("WebSocket pending frame queue exceeded its limit."); return }
            queue.append((frame, message)); queueBytes += frame.length
            if incoming.opcode == .connectionClose { closeReceived = true }
            drain()
        } catch { fail("Invalid WebSocket frame: \(error)") }
    }
    func channelReadComplete(context: ChannelHandlerContext) { if !writing, peer != nil, queue.isEmpty { context.read() } }
    private func drain() {
        guard !writing, let source, let peer, let transport else { return }
        guard !queue.isEmpty else { if source.isActive { source.read() }; return }
        let (frame, message) = queue.removeFirst()
        queueBytes -= frame.length
        writing = true
        task = Task {
            if let message { await transport.save(message) }
            do {
                try Task.checkCancellation()
                try await peer.writeAndFlush(frame).get()
                source.eventLoop.execute {
                    self.writing = false
                    self.task = nil
                    if frame.opcode == .connectionClose {
                        if transport.sawClose(self.direction) { transport.finish(); return }
                        self.closeTimeout = source.eventLoop.scheduleTask(in: .seconds(5)) { transport.finish() }
                    }
                    self.drain()
                }
            } catch { source.eventLoop.execute { self.fail("WebSocket connection closed: \(error)") } }
        }
    }
    private func fail(_ error: String) {
        queue.removeAll(); queueBytes = 0
        task?.cancel(); task = nil
        closeTimeout?.cancel(); closeTimeout = nil
        if let transport { transport.finish(error: error) }
        else { source?.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel(); task = nil; closeTimeout?.cancel(); closeTimeout = nil
        queue.removeAll(); queueBytes = 0
        transport?.finish()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail("WebSocket protocol error: \(error)") }
}
