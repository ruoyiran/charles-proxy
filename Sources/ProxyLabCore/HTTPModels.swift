import Foundation

public struct HTTPHeader: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public protocol HeaderBearing {
    var headers: [HTTPHeader] { get set }
}

public extension HeaderBearing {
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    mutating func setHeader(_ name: String, value: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        headers.append(HTTPHeader(name: name, value: value))
    }

    mutating func removeHeader(_ name: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct ProxyRequest: Codable, Sendable, HeaderBearing {
    public var method: String
    public var url: String
    public var headers: [HTTPHeader]
    public var body: Data

    public init(method: String, url: String, headers: [HTTPHeader] = [], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct ProxyResponse: Codable, Sendable, HeaderBearing {
    public var status: Int
    public var headers: [HTTPHeader]
    public var body: Data

    public init(status: Int, headers: [HTTPHeader] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct CapturedTransaction: Codable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var request: ProxyRequest
    public var response: ProxyResponse?
    public var error: String?
    public var tlsIntercepted: Bool
    public var requestBodyTruncated: Bool
    public var responseBodyTruncated: Bool

    public init(
        id: UUID = UUID(), startedAt: Date = Date(), endedAt: Date? = nil,
        request: ProxyRequest, response: ProxyResponse? = nil, error: String? = nil,
        tlsIntercepted: Bool = false, requestBodyTruncated: Bool = false,
        responseBodyTruncated: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.request = request
        self.response = response
        self.error = error
        self.tlsIntercepted = tlsIntercepted
        self.requestBodyTruncated = requestBodyTruncated
        self.responseBodyTruncated = responseBodyTruncated
    }
}

public struct TransactionSummary: Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let host: String
    public let method: String
    public let url: String
    public let status: Int?

    public init(id: UUID, startedAt: Date, host: String, method: String, url: String, status: Int?) {
        self.id = id
        self.startedAt = startedAt
        self.host = host
        self.method = method
        self.url = url
        self.status = status
    }
}
