import Foundation
import Security
import X509
import Crypto
import NIOSSL

public actor CertificateAuthority {
    public nonisolated let rootCertificatePEM: String
    public nonisolated let rootCertificateDER: Data
    private let root: Certificate
    private let privateKey: P256.Signing.PrivateKey
    private var cache: [String: (Data, NIOSSLContext)] = [:]

    public init(persistentDirectory: URL?) throws {
        let key: P256.Signing.PrivateKey
        let certificate: Certificate
        if let directory = persistentDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let certificateURL = directory.appendingPathComponent("root-ca.pem")
            if let storedKey = try Self.loadPrivateKey(),
               let storedCertificate = try? String(contentsOf: certificateURL, encoding: .utf8) {
                key = try P256.Signing.PrivateKey(rawRepresentation: storedKey)
                certificate = try Certificate(pemEncoded: storedCertificate)
                guard certificate.publicKey == Certificate.PrivateKey(key).publicKey else {
                    throw CertificateAuthorityError.corruptIdentity
                }
            } else {
                key = P256.Signing.PrivateKey()
                certificate = try Self.makeRoot(key: key)
                try Self.storePrivateKey(Data(key.rawRepresentation))
                try certificate.serializeAsPEM().pemString.write(to: certificateURL, atomically: true, encoding: .utf8)
            }
        } else {
            key = P256.Signing.PrivateKey()
            certificate = try Self.makeRoot(key: key)
        }
        self.privateKey = key
        self.root = certificate
        let pem = try certificate.serializeAsPEM().pemString
        self.rootCertificatePEM = pem
        let nio = try NIOSSLCertificate.fromPEMBytes(Array(pem.utf8))[0]
        self.rootCertificateDER = Data(try nio.toDERBytes())
    }

    public func certificateDER(for host: String) throws -> Data {
        try issue(for: host).0
    }

    public func serverContext(for host: String) throws -> NIOSSLContext {
        try issue(for: host).1
    }

    private func issue(for host: String) throws -> (Data, NIOSSLContext) {
        let canonicalHost = host.lowercased()
        guard !canonicalHost.isEmpty, canonicalHost.count <= 253,
              !canonicalHost.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }) else {
            throw CertificateAuthorityError.invalidHost
        }
        if let cached = cache[canonicalHost] { return cached }
        let leafKey = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName(canonicalHost) }
        let now = Date()
        let leaf = try Certificate(
            version: .v3,
            serialNumber: try Self.serial(),
            publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(7 * 86_400),
            issuer: root.subject,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                SubjectAlternativeNames([.dnsName(canonicalHost)])
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: .init(privateKey)
        )
        let leafPEM = try leaf.serializeAsPEM().pemString
        let cert = try NIOSSLCertificate.fromPEMBytes(Array(leafPEM.utf8))[0]
        let rootCert = try NIOSSLCertificate.fromPEMBytes(Array(rootCertificatePEM.utf8))[0]
        let keyPEM = try Certificate.PrivateKey(leafKey).serializeAsPEM().pemString
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(cert), .certificate(rootCert)], privateKey: .privateKey(key)
        )
        configuration.applicationProtocols = ["http/1.1"]
        let result = (Data(try cert.toDERBytes()), try NIOSSLContext(configuration: configuration))
        cache[canonicalHost] = result
        return result
    }

    private static func makeRoot(key: P256.Signing.PrivateKey) throws -> Certificate {
        let name = try DistinguishedName { CommonName("ProxyLab Local Root CA") }
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: try serial(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(5 * 365 * 86_400),
            issuer: name, subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: .init(key)
        )
    }

    private static func serial() throws -> Certificate.SerialNumber {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CertificateAuthorityError.randomFailure
        }
        bytes[0] &= 0x7f
        if bytes.allSatisfy({ $0 == 0 }) { bytes[15] = 1 }
        return Certificate.SerialNumber(bytes: bytes)
    }

    private static let keychainService = "com.proxylab.local-ca"

    private static func loadPrivateKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "root-p256",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CertificateAuthorityError.keychain(status) }
        return data
    }

    private static func storePrivateKey(_ key: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "root-p256",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CertificateAuthorityError.keychain(status) }
    }
}

public enum CertificateAuthorityError: Error {
    case randomFailure, invalidHost, corruptIdentity, keychain(OSStatus)
}
