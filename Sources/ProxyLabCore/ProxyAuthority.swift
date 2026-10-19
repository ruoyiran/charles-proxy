import Foundation

public struct ProxyAuthority: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public init(_ value: String) throws {
        let hostPart: String
        let portPart: String
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"),
                  value.index(after: close) < value.endIndex,
                  value[value.index(after: close)] == ":" else { throw ProxyAuthorityError.invalid }
            hostPart = String(value[value.index(after: value.startIndex)..<close])
            portPart = String(value[value.index(close, offsetBy: 2)...])
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw ProxyAuthorityError.invalid }
            hostPart = String(parts[0])
            portPart = String(parts[1])
        }
        guard !hostPart.isEmpty, !hostPart.contains(where: { $0.isWhitespace }),
              let port = Int(portPart), (1...65535).contains(port) else { throw ProxyAuthorityError.invalid }
        self.host = hostPart
        self.port = port
    }
}

public enum ProxyAuthorityError: Error { case invalid }
