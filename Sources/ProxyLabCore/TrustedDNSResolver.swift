import Foundation
import AsyncHTTPClient
import Darwin

public protocol TrustedHostResolving: Sendable {
    func resolve(host: String) async throws -> String
    func shutdown() async
}

public extension TrustedHostResolving {
    func shutdown() async {}
}

public enum TrustedDNSResolutionError: LocalizedError {
    case invalidHost, noUsableAddress, providerFailure

    public var errorDescription: String? {
        switch self {
        case .invalidHost: "The hostname is not valid for trusted DNS lookup."
        case .noUsableAddress: "Trusted DNS returned no usable public IPv4 address."
        case .providerFailure: "Trusted DNS lookup failed."
        }
    }
}

public actor GoogleHTTPSDNSResolver: TrustedHostResolving {
    private struct DNSResponse: Decodable {
        let Status: Int
        let Answer: [Answer]?

        struct Answer: Decodable {
            let type: Int
            let data: String
        }
    }

    private let client: HTTPClient
    private var cache: [String: (address: String, expires: Date)] = [:]

    public init() {
        var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow, proxy: nil)
        configuration.dnsOverride = ["dns.google": "8.8.8.8"]
        configuration.httpVersion = .http1Only
        self.client = HTTPClient(configuration: configuration)
    }

    public func resolve(host: String) async throws -> String {
        let host = host.lowercased()
        guard host.count <= 253, !host.isEmpty,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").contains($0) }),
              !host.hasPrefix("-"), !host.hasSuffix("-") else {
            throw TrustedDNSResolutionError.invalidHost
        }
        if let cached = cache[host], cached.expires > Date() { return cached.address }
        var components = URLComponents(string: "https://dns.google/resolve")!
        components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        let response = try await client.execute(HTTPClientRequest(url: components.url!.absoluteString), timeout: .seconds(8))
        guard response.status.code == 200 else { throw TrustedDNSResolutionError.providerFailure }
        let bytes = try await response.body.collect(upTo: 128 * 1_024)
        let decoded = try JSONDecoder().decode(DNSResponse.self, from: Data(buffer: bytes))
        guard decoded.Status == 0,
              let address = decoded.Answer?.first(where: { $0.type == 1 && Self.isPublicIPv4($0.data) })?.data else {
            throw TrustedDNSResolutionError.noUsableAddress
        }
        cache[host] = (address, Date().addingTimeInterval(60))
        return address
    }

    public func shutdown() async {
        try? await client.shutdown().get()
    }

    private static func isPublicIPv4(_ value: String) -> Bool {
        var parsed = in_addr()
        guard inet_pton(AF_INET, value, &parsed) == 1 else { return false }
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let a = octets[0], b = octets[1]
        return a != 0 && a != 10 && a != 127 && a < 224 &&
            !(a == 100 && (64...127).contains(b)) &&
            !(a == 169 && b == 254) &&
            !(a == 172 && (16...31).contains(b)) &&
            !(a == 192 && b == 168) &&
            !(a == 198 && (b == 18 || b == 19))
    }
}
