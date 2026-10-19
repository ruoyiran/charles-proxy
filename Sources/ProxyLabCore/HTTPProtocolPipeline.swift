import NIOCore
import NIOHTTP2

enum HTTPProtocolPipeline {
    static func configureHTTP1(channel: Channel, engine: ProxyEngine,
                               tunnelAuthority: ProxyAuthority? = nil,
                               tlsIntercepted: Bool = false) -> EventLoopFuture<Void> {
        WebSocketProxy.configureHTTP1(channel: channel, engine: engine, tunnelAuthority: tunnelAuthority,
                                      tlsIntercepted: tlsIntercepted)
    }

    /// Called after the TLS handler has been installed and before buffered TLS bytes are replayed.
    static func configureTLS(channel: Channel, engine: ProxyEngine,
                             tunnelAuthority: ProxyAuthority) -> EventLoopFuture<Void> {
        channel.configureHTTP2SecureUpgrade(h2ChannelConfigurator: { connection in
            connection.configureHTTP2Pipeline(mode: .server) { stream in
                stream.eventLoop.makeCompletedFuture {
                    try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                    // Admission and client identity belong to the physical connection, not its stream channels.
                    try stream.pipeline.syncOperations.addHandler(ProxyHTTPHandler(
                        engine: engine, tunnelAuthority: tunnelAuthority, tlsIntercepted: true,
                        clientChannel: connection, requestHTTPVersion: "HTTP/2"
                    ))
                }
            }.map { _ in }
        }, http1ChannelConfigurator: { connection in
            configureHTTP1(channel: connection, engine: engine, tunnelAuthority: tunnelAuthority,
                           tlsIntercepted: true)
        })
    }
}
