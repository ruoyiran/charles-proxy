import Foundation

public enum RequestComposerError: LocalizedError {
    case invalidURL, invalidMethod, invalidHeader, incompleteBody, unsupportedRequest
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an absolute HTTP or HTTPS URL without embedded credentials."
        case .invalidMethod: "Enter a valid HTTP method."
        case .invalidHeader: "Headers must be Name: Value lines without line breaks in their values."
        case .incompleteBody: "This request body was truncated. Load a complete body file before sending."
        case .unsupportedRequest: "CONNECT and WebSocket upgrade requests cannot be replayed as ordinary HTTP requests."
        }
    }
}

public enum RequestComposer {
    public static func normalized(_ request: ProxyRequest) throws -> ProxyRequest {
        guard var components = URLComponents(string: request.url),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              (components.port.map({ (1...65535).contains($0) }) ?? true) else { throw RequestComposerError.invalidURL }
        guard isToken(request.method) else { throw RequestComposerError.invalidMethod }
        guard request.method.uppercased() != "CONNECT", request.header("Upgrade") == nil else { throw RequestComposerError.unsupportedRequest }
        for header in request.headers {
            guard isToken(header.name), !header.value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) else {
                throw RequestComposerError.invalidHeader
            }
        }
        let connectionKeys = request.headers.filter { $0.name.caseInsensitiveCompare("Connection") == .orderedSame }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        var result = request
        result.method = request.method.uppercased()
        components.fragment = nil
        guard let url = components.url else { throw RequestComposerError.invalidURL }
        result.url = url.absoluteString
        result.headers.removeAll { ProxyEngine.isHopByHop($0.name) || connectionKeys.contains($0.name.lowercased()) }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        result.setHeader("Host", value: authority + (components.port.map { ":\($0)" } ?? ""))
        result.setHeader("Content-Length", value: String(result.body.count))
        return result
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                Array("!#$%&'*+-.^_`|~".utf8).contains($0)
        }
    }

    public static func headers(from text: String) throws -> [HTTPHeader] {
        try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw RequestComposerError.invalidHeader }
            return HTTPHeader(name: String(parts[0]).trimmingCharacters(in: .whitespaces),
                              value: String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
