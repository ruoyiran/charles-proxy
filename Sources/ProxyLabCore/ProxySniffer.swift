import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

final class ProxySniffer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Mode { case inspecting, configuringHTTP, http, connecting, tunnel, closed }
    private let engine: ProxyEngine
    private var mode: Mode = .inspecting
    private var pending = Data()
    private var tunnelTask: Task<Void, Never>?

    init(engine: ProxyEngine) { self.engine = engine }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch mode {
        case .http, .tunnel:
            context.fireChannelRead(data)
        case .closed:
            break
        case .inspecting, .configuringHTTP, .connecting:
            var part = unwrapInboundIn(data)
            if let bytes = part.readBytes(length: part.readableBytes) { pending.append(contentsOf: bytes) }
            guard pending.count <= 1_048_576 else {
                mode = .closed
                context.close(promise: nil)
                return
            }
            guard mode == .inspecting else { return }
            guard let headerEnd = pending.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = pending[..<headerEnd.lowerBound]
            guard let firstLine = String(data: head, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
                mode = .closed
                context.close(promise: nil)
                return
            }
            let tokens = firstLine.split(separator: " ")
            if tokens.count == 3, tokens[0].uppercased() == "CONNECT" {
                let target = String(tokens[1])
                pending.removeSubrange(..<headerEnd.upperBound)
                mode = .connecting
                let channel = context.channel
                tunnelTask = Task { await establishTunnel(target: target, client: channel) }
            } else {
                mode = .configuringHTTP
                let buffered = ByteBuffer(bytes: pending)
                pending.removeAll(keepingCapacity: false)
                let channel = context.channel
                HTTPProtocolPipeline.configureHTTP1(channel: channel, engine: engine).whenComplete { result in
                    switch result {
                    case .success:
                        self.mode = .http
                        channel.pipeline.fireChannelRead(buffered)
                        if !self.pending.isEmpty {
                            let remainder = ByteBuffer(bytes: self.pending)
                            self.pending.removeAll(keepingCapacity: false)
                            channel.pipeline.fireChannelRead(remainder)
                        }
                    case .failure:
                        self.mode = .closed
                        channel.close(promise: nil)
                    }
                }
            }
        }
    }

    private func establishTunnel(target: String, client: Channel) async {
        var upstream: Channel?
        do {
            try Task.checkCancellation()
            guard await engine.canForward(client) else { return }
            let authority = try ProxyAuthority(target)
            if let sslContext = try await engine.sslContext(for: authority.host) {
                try Task.checkCancellation()
                guard await engine.canForward(client) else { return }
                try await client.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")).get()
                try await client.eventLoop.submit {
                    try client.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                }.get()
                try await HTTPProtocolPipeline.configureTLS(channel: client, engine: engine,
                                                            tunnelAuthority: authority).get()
                client.eventLoop.execute {
                    self.mode = .http
                    if !self.pending.isEmpty {
                        let buffered = ByteBuffer(bytes: self.pending)
                        self.pending.removeAll(keepingCapacity: false)
                        client.pipeline.fireChannelRead(buffered)
                    }
                }
                return
            }
            let remote = try await engine.connect(authority, clientChannel: client)
            upstream = remote
            try Task.checkCancellation()
            guard await engine.canForward(client) else { try? await remote.close().get(); return }
            try await remote.pipeline.addHandler(RawRelayHandler(peer: client)).get()
            try await client.pipeline.addHandler(RawRelayHandler(peer: remote)).get()
            try await client.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")).get()
            let host = authority.host.contains(":") ? "[\(authority.host)]" : authority.host
            await engine.save(CapturedTransaction(
                startedAt: Date(), endedAt: Date(),
                request: ProxyRequest(method: "CONNECT", url: "https://\(host):\(authority.port)"),
                response: ProxyResponse(status: 200), clientAddress: client.remoteAddress?.ipAddress
            ))
            client.eventLoop.execute {
                self.mode = .tunnel
                if !self.pending.isEmpty {
                    let buffered = ByteBuffer(bytes: self.pending)
                    self.pending.removeAll(keepingCapacity: false)
                    client.pipeline.fireChannelRead(buffered)
                }
            }
        } catch {
            if let upstream { try? await upstream.close().get() }
            let message = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            try? await client.writeAndFlush(ByteBuffer(string: message)).get()
            try? await client.close().get()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        tunnelTask?.cancel()
        tunnelTask = nil
        context.fireChannelInactive()
    }
}

private final class RawRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
