import Foundation
import NIOCore

final class MobileAdmissionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let engine: ProxyEngine

    init(engine: ProxyEngine) { self.engine = engine }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        Task {
            if await engine.admit(channel) {
                do {
                    try await channel.pipeline.addHandler(ProxySniffer(engine: engine)).get()
                    try await channel.setOption(ChannelOptions.autoRead, value: true).get()
                    channel.read()
                } catch { try? await channel.close().get() }
            } else {
                let body = "Allow this device in ProxyLab Mobile Setup, then retry."
                let message = "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                try? await channel.writeAndFlush(ByteBuffer(string: message)).get()
                try? await channel.close().get()
            }
        }
        context.fireChannelActive()
    }
}
