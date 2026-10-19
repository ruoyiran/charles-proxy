import Foundation

public struct CaptureRule: Codable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var match: RuleMatch
    public var clientAddress: String?

    public init(id: UUID = UUID(), enabled: Bool = true, match: RuleMatch, clientAddress: String? = nil) {
        self.id = id; self.enabled = enabled; self.match = match; self.clientAddress = clientAddress
    }

    public func matches(request: ProxyRequest, clientAddress: String?) -> Bool {
        enabled && match.matches(request) && (self.clientAddress == nil || self.clientAddress == clientAddress)
    }
}

public struct CapturePolicy: Codable, Sendable {
    public var include: [CaptureRule]
    public var exclude: [CaptureRule]
    public init(include: [CaptureRule] = [], exclude: [CaptureRule] = []) { self.include = include; self.exclude = exclude }
    public func shouldRecord(request: ProxyRequest, clientAddress: String?) -> Bool {
        if exclude.contains(where: { $0.matches(request: request, clientAddress: clientAddress) }) { return false }
        let active = include.filter(\.enabled)
        return active.isEmpty || active.contains { $0.matches(request: request, clientAddress: clientAddress) }
    }
}

public struct FocusPolicy: Codable, Sendable {
    public var enabled: Bool
    public var rules: [CaptureRule]
    public init(enabled: Bool = false, rules: [CaptureRule] = []) { self.enabled = enabled; self.rules = rules }
    public func matches(_ summary: TransactionSummary) -> Bool {
        !enabled || rules.contains { $0.matches(request: ProxyRequest(method: summary.method, url: summary.url), clientAddress: summary.clientAddress) }
    }
}
