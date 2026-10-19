import Foundation

public struct BreakpointRule: Codable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var match: RuleMatch
    public var phase: RulePhase

    public init(id: UUID = UUID(), enabled: Bool = true, match: RuleMatch, phase: RulePhase) {
        self.id = id
        self.enabled = enabled
        self.match = match
        self.phase = phase
    }
}

public struct PendingBreakpoint: Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let phase: RulePhase
    public let request: ProxyRequest
    public let response: ProxyResponse?
    public let bodyTruncated: Bool
}

public enum BreakpointDecision: Sendable {
    case execute(request: ProxyRequest?, response: ProxyResponse?)
    case cancel
    case abort
}

public actor BreakpointCenter {
    private var rules: [BreakpointRule] = []
    private var waiting: [UUID: CheckedContinuation<BreakpointDecision, Never>] = [:]
    private var items: [UUID: PendingBreakpoint] = [:]

    public init() {}

    public func setRules(_ rules: [BreakpointRule]) { self.rules = rules }
    public func currentRules() -> [BreakpointRule] { rules }

    public func shouldIntercept(request: ProxyRequest, phase: RulePhase) -> Bool {
        rules.contains { $0.enabled && $0.phase == phase && $0.match.matches(request) }
    }

    public func pending() -> [PendingBreakpoint] {
        items.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func intercept(request: ProxyRequest, response: ProxyResponse?, phase: RulePhase,
                          timeout: Duration = .seconds(120), bodyTruncated: Bool = false) async -> BreakpointDecision {
        guard shouldIntercept(request: request, phase: phase) else {
            return .cancel
        }
        let id = UUID()
        let item = PendingBreakpoint(id: id, createdAt: Date(), phase: phase,
                                     request: request, response: response, bodyTruncated: bodyTruncated)
        return await withCheckedContinuation { continuation in
            items[id] = item
            waiting[id] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.resolve(id: id, decision: .cancel)
            }
        }
    }

    public func resolve(id: UUID, decision: BreakpointDecision) {
        items.removeValue(forKey: id)
        waiting.removeValue(forKey: id)?.resume(returning: decision)
    }

    public func cancelAll() {
        for id in Array(waiting.keys) { resolve(id: id, decision: .cancel) }
    }
}
