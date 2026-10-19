import Foundation
import Security
import SystemConfiguration

public enum SystemProxyPatcher {
    private static let managedKeys = [
        "HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
        "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable",
    ]

    public static func enable(_ original: [String: Any], port: Int) -> [String: Any] {
        var result = original
        result["HTTPEnable"] = 1
        result["HTTPProxy"] = "127.0.0.1"
        result["HTTPPort"] = port
        result["HTTPSEnable"] = 1
        result["HTTPSProxy"] = "127.0.0.1"
        result["HTTPSPort"] = port
        result["ProxyAutoConfigEnable"] = 0
        result["ProxyAutoDiscoveryEnable"] = 0
        return result
    }

    public static func restore(current: [String: Any], original: [String: Any], port: Int) -> [String: Any]? {
        let owned = enable(original, port: port)
        guard managedKeys.allSatisfy({ key in
            guard let expected = owned[key] as? NSObject else { return current[key] == nil }
            if current[key] == nil,
               (key == "ProxyAutoConfigEnable" || key == "ProxyAutoDiscoveryEnable"),
               (expected as? NSNumber)?.intValue == 0 { return true }
            return (current[key] as? NSObject)?.isEqual(expected) == true
        }) else { return nil }
        var result = current
        for key in managedKeys {
            if let originalValue = original[key] { result[key] = originalValue }
            else { result.removeValue(forKey: key) }
        }
        return result
    }
}

public enum SystemProxyError: LocalizedError {
    case authorization(OSStatus), preferences(Int32), noServices, conflict, pendingRestore

    public var errorDescription: String? {
        switch self {
        case .authorization(let code): "System authorization failed (\(code))."
        case .preferences(let code): "System proxy preferences could not be changed (\(code))."
        case .noServices: "No enabled network services were found."
        case .conflict: "Network proxy settings changed outside ProxyLab; they were not overwritten."
        case .pendingRestore: "Previous proxy settings must be restored before enabling again."
        }
    }
}

@MainActor
public final class SystemProxyManager {
    private let snapshotURL: URL

    public init(snapshotURL: URL) { self.snapshotURL = snapshotURL }

    public var hasPendingRestore: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }

    public func enable(port: Int) throws {
        guard !hasPendingRestore else { throw SystemProxyError.pendingRestore }
        let (preferences, authorization) = try openPreferences()
        defer { AuthorizationFree(authorization, []) }
        let services = (SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? []).filter {
            SCNetworkServiceGetEnabled($0)
        }
        guard !services.isEmpty else { throw SystemProxyError.noServices }
        var originals: [String: [String: Any]] = [:]
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let original = (SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any]) ?? [:]
            originals[id] = original
        }
        guard !originals.isEmpty else { throw SystemProxyError.noServices }
        let snapshot: [String: Any] = ["port": port, "services": originals]
        let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
        try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: snapshotURL, options: .atomic)
        do {
            for service in services {
                guard let id = SCNetworkServiceGetServiceID(service) as String?,
                      let original = originals[id],
                      let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                let enabled = SystemProxyPatcher.enable(original, port: port)
                guard SCNetworkProtocolSetConfiguration(proxyProtocol, enabled as CFDictionary) else {
                    throw SystemProxyError.preferences(SCError())
                }
            }
            try commit(preferences)
        } catch {
            // A failed commit has not changed the running configuration; keep the snapshot if it did.
            throw error
        }
    }

    public func restore() throws {
        guard hasPendingRestore else { return }
        let data = try Data(contentsOf: snapshotURL)
        guard let snapshot = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let port = snapshot["port"] as? Int,
              let originals = snapshot["services"] as? [String: [String: Any]] else {
            throw SystemProxyError.conflict
        }
        let (preferences, authorization) = try openPreferences()
        defer { AuthorizationFree(authorization, []) }
        let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? []
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let original = originals[id],
                  let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let current = (SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any]) ?? [:]
            guard let restored = SystemProxyPatcher.restore(current: current, original: original, port: port) else {
                throw SystemProxyError.conflict
            }
            guard SCNetworkProtocolSetConfiguration(proxyProtocol, restored as CFDictionary) else {
                throw SystemProxyError.preferences(SCError())
            }
        }
        try commit(preferences)
        try FileManager.default.removeItem(at: snapshotURL)
    }

    private func openPreferences() throws -> (SCPreferences, AuthorizationRef) {
        var authorization: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights], &authorization)
        guard status == errAuthorizationSuccess, let authorization else { throw SystemProxyError.authorization(status) }
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "ProxyLab" as CFString, nil, authorization) else {
            AuthorizationFree(authorization, [])
            throw SystemProxyError.preferences(SCError())
        }
        return (preferences, authorization)
    }

    private func commit(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw SystemProxyError.preferences(SCError())
        }
    }
}
