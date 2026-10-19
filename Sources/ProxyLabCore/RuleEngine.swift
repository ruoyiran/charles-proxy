import Foundation
import Darwin

public enum RulePhase: String, Codable, Sendable { case request, response }

public struct RuleMatch: Codable, Sendable {
    public var host: String
    public var path: String
    public var method: String?

    public init(host: String, path: String = "/*", method: String? = nil) {
        self.host = host
        self.path = path
        self.method = method
    }

    public func matches(_ request: ProxyRequest) -> Bool {
        guard let url = URL(string: request.url), let actualHost = url.host?.lowercased() else { return false }
        let expectedHost = host.lowercased()
        let hostMatches: Bool
        if expectedHost == "*" {
            hostMatches = true
        } else if expectedHost.hasPrefix("*.") {
            let suffix = String(expectedHost.dropFirst(1))
            hostMatches = actualHost.hasSuffix(suffix) && actualHost != String(expectedHost.dropFirst(2))
        } else {
            hostMatches = actualHost == expectedHost
        }
        let pathMatches = fnmatch(path, url.path.isEmpty ? "/" : url.path, 0) == 0
        let methodMatches = method.map { $0.caseInsensitiveCompare(request.method) == .orderedSame } ?? true
        return hostMatches && pathMatches && methodMatches
    }
}

public enum RuleAction: Codable, Sendable {
    case setHeader(name: String, value: String)
    case removeHeader(name: String)
    case replaceText(find: String, replace: String)
    case replaceURL(String)
}

public struct RewriteRule: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: RuleMatch
    public var phase: RulePhase
    public var action: RuleAction

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, match: RuleMatch,
                phase: RulePhase, action: RuleAction) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.phase = phase
        self.action = action
    }
}

public enum RuleEngine {
    public static func applyRequest(_ request: inout ProxyRequest, rules: [RewriteRule]) {
        for rule in rules where rule.enabled && rule.phase == .request && rule.match.matches(request) {
            switch rule.action {
            case .setHeader(let name, let value): request.setHeader(name, value: value)
            case .removeHeader(let name): request.removeHeader(name)
            case .replaceURL(let value):
                if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    request.url = value
                    if let host = url.host {
                        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
                        request.setHeader("Host", value: authority + (url.port.map { ":\($0)" } ?? ""))
                    }
                }
            case .replaceText(let find, let replace):
                replaceText(&request.body, headers: &request.headers, find: find, replace: replace)
            }
        }
    }

    public static func applyResponse(_ response: inout ProxyResponse, for request: ProxyRequest,
                                     rules: [RewriteRule]) {
        for rule in rules where rule.enabled && rule.phase == .response && rule.match.matches(request) {
            switch rule.action {
            case .setHeader(let name, let value): response.setHeader(name, value: value)
            case .removeHeader(let name): response.removeHeader(name)
            case .replaceText(let find, let replace):
                replaceText(&response.body, headers: &response.headers, find: find, replace: replace)
            case .replaceURL: break
            }
        }
    }

    private static func replaceText(_ body: inout Data, headers: inout [HTTPHeader], find: String, replace: String) {
        guard !find.isEmpty,
              let type = headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value.lowercased(),
              type.hasPrefix("text/") || type.contains("json") || type.contains("xml") || type.contains("javascript") || type.contains("x-www-form-urlencoded"),
              !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame && $0.value.lowercased() != "identity" }),
              let original = String(data: body, encoding: .utf8) else { return }
        let updated = original.replacingOccurrences(of: find, with: replace)
        guard updated != original else { return }
        body = Data(updated.utf8)
        headers.removeAll { $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame || $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
        headers.append(HTTPHeader(name: "Content-Length", value: String(body.count)))
    }
}
