import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

public actor ProxyEngine {
    public nonisolated let breakpointCenter: BreakpointCenter
    private let store: SessionStore
    private let group: MultiThreadedEventLoopGroup
    private let client: HTTPClient
    private var listener: Channel?
    private var rules: [RewriteRule] = []
    private var certificateAuthority: CertificateAuthority?
    private var sslHosts: [String] = []
    private var recordingEnabled = true

    public init(store: SessionStore, upstreamTLSConfiguration: TLSConfiguration? = nil,
                breakpointCenter: BreakpointCenter = BreakpointCenter()) {
        self.store = store
        self.breakpointCenter = breakpointCenter
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        var configuration = HTTPClient.Configuration(tlsConfiguration: upstreamTLSConfiguration,
                                                     redirectConfiguration: .disallow, proxy: nil,
                                                     decompression: .disabled)
        configuration.httpVersion = .http1Only
        self.client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
    }

    @discardableResult
    public func start(port: Int = 8888) async throws -> Int {
        if let listener { return listener.localAddress?.port ?? port }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ProxySniffer(engine: self))
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        listener = channel
        return channel.localAddress?.port ?? port
    }

    public func stop() async {
        await breakpointCenter.cancelAll()
        if let listener {
            try? await listener.close().get()
            self.listener = nil
        }
        try? await client.shutdown().get()
        try? await group.shutdownGracefully()
    }

    public func setRules(_ rules: [RewriteRule]) {
        self.rules = rules
    }

    public func setRecordingEnabled(_ enabled: Bool) { recordingEnabled = enabled }

    public func configureTLS(authority: CertificateAuthority, includeHosts: [String]) {
        certificateAuthority = authority
        sslHosts = includeHosts.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func sslContext(for host: String) async throws -> NIOSSLContext? {
        let host = host.lowercased()
        guard let certificateAuthority,
              sslHosts.contains(where: { pattern in
                  pattern == host || pattern == "*" ||
                  (pattern.hasPrefix("*.") && host.hasSuffix(String(pattern.dropFirst(1))))
              }) else { return nil }
        return try await certificateAuthority.serverContext(for: host)
    }

    func prepare(_ request: ProxyRequest, allowBodyChanges: Bool = true) -> ProxyRequest {
        var request = request
        let applicable = allowBodyChanges ? rules : rules.filter {
            if case .replaceText = $0.action { return false }
            return true
        }
        RuleEngine.applyRequest(&request, rules: applicable)
        if rules.contains(where: { rule in
            guard rule.enabled && rule.phase == .response && rule.match.matches(request) else { return false }
            if case .replaceText = rule.action { return true }
            return false
        }) {
            request.setHeader("Accept-Encoding", value: "identity")
        }
        return request
    }

    func execute(_ request: ProxyRequest, bodyFile: URL? = nil, bodyLength: Int = 0) async throws -> HTTPClientResponse {
        guard let target = URL(string: request.url),
              let host = target.host?.lowercased(),
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ProxyRequestError.invalidURL
        }
        let port = target.port ?? (scheme == "https" ? 443 : 80)
        if ["localhost", "127.0.0.1", "::1"].contains(host), listener?.localAddress?.port == port {
            throw ProxyRequestError.selfLoop
        }
        var outgoing = HTTPClientRequest(url: request.url)
        outgoing.method = HTTPMethod(rawValue: request.method)
        for header in request.headers where !Self.isHopByHop(header.name) && header.name.lowercased() != "content-length" {
            outgoing.headers.add(name: header.name, value: header.value)
        }
        if let bodyFile {
            let handle = try FileHandle(forReadingFrom: bodyFile)
            outgoing.body = .stream(handle.bytes, length: .known(Int64(bodyLength)))
        } else if !request.body.isEmpty {
            outgoing.body = .bytes(ByteBuffer(bytes: request.body))
        }
        return try await client.execute(outgoing, timeout: .seconds(120))
    }

    func rewriteResponse(_ response: inout ProxyResponse, for request: ProxyRequest,
                         allowBodyChanges: Bool = true) {
        let applicable = allowBodyChanges ? rules : rules.filter {
            if case .replaceText = $0.action { return false }
            return true
        }
        RuleEngine.applyResponse(&response, for: request, rules: applicable)
    }

    func responseNeedsBuffer(for request: ProxyRequest) async -> Bool {
        if rules.contains(where: { $0.enabled && $0.phase == .response && $0.match.matches(request) }) {
            return true
        }
        return await breakpointCenter.shouldIntercept(request: request, phase: .response)
    }

    func save(_ transaction: CapturedTransaction) async {
        if recordingEnabled { try? await store.save(transaction) }
    }

    func connect(_ authority: ProxyAuthority) async throws -> Channel {
        if ["localhost", "127.0.0.1", "::1"].contains(authority.host.lowercased()),
           listener?.localAddress?.port == authority.port {
            throw ProxyAuthorityError.invalid
        }
        return try await ClientBootstrap(group: group)
            .connect(host: authority.host, port: authority.port).get()
    }

    static func isHopByHop(_ name: String) -> Bool {
        ["connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization"].contains(name.lowercased())
    }
}

public enum ProxyRequestError: LocalizedError {
    case invalidURL, selfLoop

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid HTTP target URL."
        case .selfLoop: "Request targets ProxyLab's own listening address."
        }
    }
}
