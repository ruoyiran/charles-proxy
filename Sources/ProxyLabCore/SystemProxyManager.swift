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
        if matches(current: current, expected: original) { return current }
        let owned = enable(original, port: port)
        guard matches(current: current, expected: owned) else { return nil }
        var result = current
        for key in managedKeys {
            if let originalValue = original[key] { result[key] = originalValue }
            else { result.removeValue(forKey: key) }
        }
        return result
    }

    private static func matches(current: [String: Any], expected: [String: Any]) -> Bool {
        managedKeys.allSatisfy { key in
            if key.hasSuffix("Enable") {
                // SystemConfiguration may omit disabled flags instead of storing zero.
                let currentFlag = (current[key] as? NSNumber)?.intValue ?? 0
                let expectedFlag = (expected[key] as? NSNumber)?.intValue ?? 0
                return currentFlag == expectedFlag
            }
            guard let value = expected[key] as? NSObject else { return current[key] == nil }
            return (current[key] as? NSObject)?.isEqual(value) == true
        }
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
    private let configurationReader: () throws -> [String: [String: Any]]
    private let pendingApply: (() throws -> Void)?

    public init(snapshotURL: URL, configurationReader: (() throws -> [String: [String: Any]])? = nil,
                pendingApply: (() throws -> Void)? = nil) {
        self.snapshotURL = snapshotURL
        self.configurationReader = configurationReader ?? Self.readConfigurations
        self.pendingApply = pendingApply
    }

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
        guard var snapshot = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let port = snapshot["port"] as? Int,
              let originals = snapshot["services"] as? [String: [String: Any]] else {
            throw SystemProxyError.conflict
        }
        // A previous restore, failed enable, or manual change may already have restored
        // every service. Clear stale recovery state without prompting for authorization.
        let configurations = try configurationReader()
        var needsChanges = false
        for (id, original) in originals {
            guard let current = configurations[id] else { continue }
            guard let restored = SystemProxyPatcher.restore(current: current, original: original, port: port) else {
                throw SystemProxyError.conflict
            }
            if !(current as NSDictionary).isEqual(to: restored) { needsChanges = true }
        }
        let requiresApply = snapshot["restoreNeedsApply"] as? Bool ?? false
        if !needsChanges, !requiresApply {
            try FileManager.default.removeItem(at: snapshotURL)
            return
        }
        if !needsChanges, requiresApply, let pendingApply {
            try pendingApply()
            try FileManager.default.removeItem(at: snapshotURL)
            return
        }
        let (preferences, authorization) = try openPreferences()
        defer { AuthorizationFree(authorization, []) }
        let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? []
        // Validate all services before staging any changes. Re-read after authorization
        // so a user's intervening changes are never overwritten.
        var changes: [(SCNetworkProtocol, [String: Any])] = []
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let original = originals[id],
                  let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let current = (SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any]) ?? [:]
            guard let restored = SystemProxyPatcher.restore(current: current, original: original, port: port) else {
                throw SystemProxyError.conflict
            }
            if !(current as NSDictionary).isEqual(to: restored) { changes.append((proxyProtocol, restored)) }
        }
        for (proxyProtocol, restored) in changes {
            guard SCNetworkProtocolSetConfiguration(proxyProtocol, restored as CFDictionary) else {
                throw SystemProxyError.preferences(SCError())
            }
        }
        if !changes.isEmpty {
            // Commit and apply are separate operations. Persist this marker first so a
            // failed apply can be retried even after disk settings match the originals.
            snapshot["restoreNeedsApply"] = true
            try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
                .write(to: snapshotURL, options: .atomic)
            try commit(preferences)
        } else if requiresApply {
            guard SCPreferencesApplyChanges(preferences) else { throw SystemProxyError.preferences(SCError()) }
        }
        try FileManager.default.removeItem(at: snapshotURL)
    }

    private static func readConfigurations() throws -> [String: [String: Any]] {
        guard let preferences = SCPreferencesCreate(nil, "ProxyLab" as CFString, nil) else {
            throw SystemProxyError.preferences(SCError())
        }
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            throw SystemProxyError.noServices
        }
        var result: [String: [String: Any]] = [:]
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            result[id] = SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any] ?? [:]
        }
        return result
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
