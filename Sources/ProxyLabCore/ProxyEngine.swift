import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

public actor ProxyEngine {
    public nonisolated let breakpointCenter: BreakpointCenter
    public nonisolated let mobileAccess = MobileAccess()
    private let store: SessionStore
    private let group: MultiThreadedEventLoopGroup
    private let client: HTTPClient
    private var routedClients: [String: HTTPClient] = [:]
    private let upstreamTLSConfiguration: TLSConfiguration?
    private var listener: Channel?
    private var mobileEnabled = false
    private var clientChannels: [ObjectIdentifier: Channel] = [:]
    private var accessGeneration = 0
    private var blockedDevices: Set<String> = []
    private var listenerTransition: Task<Void, Never>?
    private var rules: [RewriteRule] = []
    private var certificateAuthority: CertificateAuthority?
    private var sslHosts: [String] = []
    private var recordingEnabled = true
    private var capturePolicy = CapturePolicy()
    private var recordedWebSockets: Set<UUID> = []
    private var pendingWebSockets: Set<UUID> = []
    private var deletedWebSockets: Set<UUID> = []
    private var webSocketRequests: [UUID: (ProxyRequest, String?)] = [:]
    private var recordingGeneration = 0
    private let connectAddressOverrides: [String: String]
    private let trustedResolver: (any TrustedHostResolving)?
    private var trustedDNSHosts: Set<String>

    public init(store: SessionStore, upstreamTLSConfiguration: TLSConfiguration? = nil,
                breakpointCenter: BreakpointCenter = BreakpointCenter(),
                connectAddressOverrides: [String: String] = [:],
                trustedResolver: (any TrustedHostResolving)? = nil,
                trustedDNSHosts: Set<String> = []) {
        self.store = store
        self.breakpointCenter = breakpointCenter
        self.connectAddressOverrides = connectAddressOverrides
        self.trustedResolver = trustedResolver
        self.trustedDNSHosts = Set(trustedDNSHosts.map { $0.lowercased() })
        self.upstreamTLSConfiguration = upstreamTLSConfiguration
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        var configuration = HTTPClient.Configuration(tlsConfiguration: upstreamTLSConfiguration,
                                                     redirectConfiguration: .disallow, proxy: nil,
                                                     decompression: .disabled)
        configuration.httpVersion = .automatic
        configuration.dnsOverride = connectAddressOverrides
        self.client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
    }

    @discardableResult
    public func start(port: Int = 8888) async throws -> Int {
        try await withListenerTransition { try await self.startListener(port: port) }
    }

    private func startListener(port: Int) async throws -> Int {
        if let listener { return listener.localAddress?.port ?? port }
        return try await bind(port: port)
    }

    private func bind(port: Int) async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(MobileAdmissionHandler(engine: self))
            }
        let channel = try await bootstrap.bind(host: mobileEnabled ? "0.0.0.0" : "127.0.0.1", port: port).get()
        listener = channel
        return channel.localAddress?.port ?? port
    }

    public func stop() async {
        _ = try? await withListenerTransition { await self.stopNow() }
    }

    private func stopNow() async {
        accessGeneration += 1
        mobileEnabled = false
        await breakpointCenter.cancelAll()
        if let listener {
            try? await listener.close().get()
            self.listener = nil
        }
        for channel in Array(clientChannels.values) { try? await channel.close().get() }
        clientChannels.removeAll()
        await mobileAccess.setEnabled(false)
        try? await client.shutdown().get()
        for routedClient in routedClients.values { try? await routedClient.shutdown().get() }
        routedClients.removeAll()
        await trustedResolver?.shutdown()
        try? await group.shutdownGracefully()
    }

    public func setMobileConnectionsEnabled(_ enabled: Bool) async throws {
        try await withListenerTransition { try await self.setMobileNow(enabled) }
    }

    private func setMobileNow(_ enabled: Bool) async throws {
        guard enabled != mobileEnabled else { return }
        accessGeneration += 1
        let previous = mobileEnabled
        let port = listener?.localAddress?.port
        if let listener { try await listener.close().get(); self.listener = nil }
        mobileEnabled = enabled
        do {
            if let port { _ = try await bind(port: port) }
            await mobileAccess.setEnabled(enabled)
        } catch {
            mobileEnabled = previous
            if let port { _ = try? await bind(port: port) }
            throw error
        }
        if !enabled {
            blockedDevices.removeAll()
            for channel in Array(clientChannels.values) where !MobileAccess.isLoopback(channel.remoteAddress?.ipAddress ?? "") {
                clientChannels.removeValue(forKey: ObjectIdentifier(channel))
                try? await channel.close().get()
            }
        }
    }

    func admit(_ channel: Channel) async -> Bool {
        let generation = accessGeneration
        guard let address = channel.remoteAddress?.ipAddress,
              !blockedDevices.contains(address),
              await mobileAccess.authorize(address: address) else { return false }
        guard !blockedDevices.contains(address), channel.isActive,
              MobileAccess.isLoopback(address) || (mobileEnabled && generation == accessGeneration) else { return false }
        let id = ObjectIdentifier(channel)
        clientChannels[id] = channel
        channel.closeFuture.whenComplete { _ in Task { await self.removeClient(id) } }
        return true
    }

    private func removeClient(_ id: ObjectIdentifier) { clientChannels.removeValue(forKey: id) }

    public func setDeviceAccess(_ access: DeviceAccess, address: String) async {
        accessGeneration += 1
        blockedDevices.insert(address)
        let channels = Array(clientChannels.values).filter { $0.remoteAddress?.ipAddress == address }
        if access != .allowed {
            for channel in channels { clientChannels.removeValue(forKey: ObjectIdentifier(channel)) }
        }
        await mobileAccess.setAccess(access, address: address)
        if access == .allowed { blockedDevices.remove(address) }
        if access != .allowed {
            for channel in channels {
                try? await channel.close().get()
            }
        }
    }

    func canForward(_ channel: Channel) -> Bool {
        channel.isActive && clientChannels[ObjectIdentifier(channel)] != nil
    }

    private func withListenerTransition<T: Sendable>(_ action: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = listenerTransition
        let task = Task { await previous?.value; return try await action() }
        listenerTransition = Task { _ = try? await task.value }
        return try await task.value
    }

    func mobileSetupResponse(for request: ProxyRequest) -> MobileSetupResponse? {
        guard let authority = certificateAuthority, let port = listener?.localAddress?.port else { return nil }
        return MobileSetupPage.response(for: request.url, method: request.method, port: port,
                                        certificateDER: authority.rootCertificateDER,
                                        localAddresses: LANAddress.available().map(\.address))
    }

    public func setRules(_ rules: [RewriteRule]) {
        self.rules = rules
    }

    public func setRecordingEnabled(_ enabled: Bool) { recordingEnabled = enabled }
    public func setCapturePolicy(_ policy: CapturePolicy) { capturePolicy = policy }

    func beginWebSocket(_ transaction: CapturedTransaction) async -> Bool {
        let generation = recordingGeneration
        guard recordingEnabled, capturePolicy.shouldRecord(request: transaction.request, clientAddress: transaction.clientAddress) else { return false }
        pendingWebSockets.insert(transaction.id)
        defer { pendingWebSockets.remove(transaction.id) }
        do {
            try await store.save(transaction)
            guard generation == recordingGeneration, !deletedWebSockets.contains(transaction.id) else {
                try? await store.remove(id: transaction.id)
                return false
            }
            recordedWebSockets.insert(transaction.id)
            webSocketRequests[transaction.id] = (transaction.request, transaction.clientAddress)
            return true
        } catch { return false }
    }

    func saveWebSocketMessage(_ message: WebSocketMessage, transactionID: UUID) async {
        guard recordingEnabled, recordedWebSockets.contains(transactionID),
              let (request, address) = webSocketRequests[transactionID], capturePolicy.shouldRecord(request: request, clientAddress: address) else { return }
        do {
            try await store.saveWebSocketMessage(message, transactionID: transactionID)
        } catch {}
    }

    func finishWebSocket(_ transaction: CapturedTransaction) async {
        guard recordedWebSockets.remove(transaction.id) != nil else { return }
        webSocketRequests.removeValue(forKey: transaction.id)
        try? await store.save(transaction)
    }

    public func clearSession() async throws {
        recordingGeneration += 1
        deletedWebSockets.formUnion(pendingWebSockets)
        recordedWebSockets.removeAll()
        webSocketRequests.removeAll()
        try await store.clear()
    }

    public func deleteTransaction(_ id: UUID) async throws {
        deletedWebSockets.insert(id)
        recordedWebSockets.remove(id)
        webSocketRequests.removeValue(forKey: id)
        try await store.remove(id: id)
    }

    public func replay(_ original: ProxyRequest, replayOf: UUID? = nil) async throws -> CapturedTransaction {
        let request = try RequestComposer.normalized(original)
        var transaction = CapturedTransaction(request: request, clientAddress: "127.0.0.1", replayOf: replayOf)
        do {
            let response = try await execute(request)
            transaction.responseHTTPVersion = Self.versionLabel(response.version)
            transaction.requestHTTPVersion = transaction.responseHTTPVersion
            var body = Data()
            var total = 0
            for try await var part in response.body {
                total += part.readableBytes
                if let bytes = part.readBytes(length: min(part.readableBytes, max(0, 10 * 1024 * 1024 - body.count))) {
                    body.append(contentsOf: bytes)
                }
            }
            transaction.responseTrailers = response.body.trailers?.map { HTTPHeader(name: $0.name, value: $0.value) }
            transaction.response = ProxyResponse(status: Int(response.status.code),
                                                   headers: response.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
                                                       .filter { !Self.isHopByHop($0.name) }, body: body)
            transaction.responseBodyTruncated = total > body.count
        } catch { transaction.error = String(describing: error) }
        transaction.endedAt = Date()
        // Explicit sends always keep their result, even while automatic recording is paused.
        try await store.save(transaction)
        return transaction
    }

    public func setTrustedDNSHosts(_ hosts: Set<String>) {
        trustedDNSHosts = Set(hosts.map { $0.lowercased() })
    }

    public func configureTLS(authority: CertificateAuthority, includeHosts: [String] = ["*"]) {
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

    func execute(_ request: ProxyRequest, bodyFile: URL? = nil, bodyLength: Int = 0,
                 clientChannel: Channel? = nil) async throws -> HTTPClientResponse {
        try Task.checkCancellation()
        if let clientChannel, !canForward(clientChannel) { throw CancellationError() }
        guard let target = URL(string: request.url),
              let host = target.host?.lowercased(),
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ProxyRequestError.invalidURL
        }
        let port = target.port ?? (scheme == "https" ? 443 : 80)
        if isListenerTarget(host: host, port: port) {
            throw ProxyRequestError.selfLoop
        }
        let address = try await routeAddress(for: host)
        let requestClient: HTTPClient
        if let address {
            let key = "\(host)|\(address)"
            if let cached = routedClients[key] {
                requestClient = cached
            } else {
                var configuration = HTTPClient.Configuration(tlsConfiguration: upstreamTLSConfiguration,
                                                             redirectConfiguration: .disallow, proxy: nil,
                                                             decompression: .disabled)
                configuration.httpVersion = .automatic
                configuration.dnsOverride = [host: address]
                let routed = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
                routedClients[key] = routed
                requestClient = routed
            }
        } else {
            requestClient = client
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
        try Task.checkCancellation()
        if let clientChannel, !canForward(clientChannel) { throw CancellationError() }
        return try await requestClient.execute(outgoing, timeout: .seconds(120))
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
        if recordingEnabled && capturePolicy.shouldRecord(request: transaction.request, clientAddress: transaction.clientAddress) {
            try? await store.save(transaction)
        }
    }

    func webSocketTLSConfiguration() -> TLSConfiguration {
        var configuration = upstreamTLSConfiguration ?? .makeClientConfiguration()
        configuration.applicationProtocols = ["http/1.1"]
        return configuration
    }

    func connect(_ authority: ProxyAuthority, clientChannel: Channel? = nil) async throws -> Channel {
        try Task.checkCancellation()
        if isListenerTarget(host: authority.host.lowercased(), port: authority.port) {
            throw ProxyAuthorityError.invalid
        }
        let host = authority.host.lowercased()
        let address = try await routeAddress(for: host)
        try Task.checkCancellation()
        if let clientChannel, !canForward(clientChannel) { throw CancellationError() }
        return try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(8))
            .connect(host: address ?? authority.host, port: authority.port).get()
    }

    private func isListenerTarget(host: String, port: Int) -> Bool {
        listener?.localAddress?.port == port &&
            (host == "localhost" || MobileAccess.isLoopback(host) || LANAddress.available().contains { $0.address == host })
    }

    private func routeAddress(for host: String) async throws -> String? {
        if let override = connectAddressOverrides[host] { return override }
        guard trustedDNSHosts.contains(host) else { return nil }
        guard let trustedResolver else { throw TrustedDNSResolutionError.providerFailure }
        return try await trustedResolver.resolve(host: host)
    }

    static func isHopByHop(_ name: String) -> Bool {
        ["connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization"].contains(name.lowercased())
    }

    static func versionLabel(_ version: HTTPVersion) -> String {
        version.major == 2 ? "HTTP/2" : "HTTP/\(version.major).\(version.minor)"
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
