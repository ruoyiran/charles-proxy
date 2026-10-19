import AppKit
import Foundation
import ProxyLabCore
import Security
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var summaries: [TransactionSummary] = []
    @Published var selectedID: UUID?
    @Published var selectedTransaction: CapturedTransaction?
    @Published var pendingBreakpoints: [PendingBreakpoint] = []
    @Published var rewriteRules: [RewriteRule] = []
    @Published var breakpointRules: [BreakpointRule] = []
    @Published var sslHostsText = ""
    @Published var trustedDNSHostsText = ""
    @Published var recordingEnabled = true
    @Published var systemProxyEnabled = false
    @Published var hasPendingRestore = false
    @Published var proxyPort = 8888
    @Published var statusText = "Starting proxy…"
    @Published var errorMessage: String?
    @Published var rootCertificateStatus = "Not checked"
    @Published var isCheckingCertificateTrust = false
    @Published var certificateTrustCheckedAt: Date?
    @Published var sslSetupInProgress = false

    private let supportDirectory: URL
    private let proxySettings: SystemProxyManager
    private let certificateTrustEvaluator: @Sendable (URL) async -> String
    private var store: SessionStore?
    private var engine: ProxyEngine?
    private var authority: CertificateAuthority?
    private var authorityTask: Task<CertificateAuthority, Error>?
    private var refreshTask: Task<Void, Never>?
    private var started = false

    init(certificateTrustEvaluator: @escaping @Sendable (URL) async -> String = { url in
        await Task.detached { AppModel.evaluateRootCertificate(at: url) }.value
    }) {
        self.certificateTrustEvaluator = certificateTrustEvaluator
        supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyLab", isDirectory: true)
        proxySettings = SystemProxyManager(snapshotURL: supportDirectory.appendingPathComponent("proxy-snapshot.plist"))
        hasPendingRestore = proxySettings.hasPendingRestore
        if let rules = try? Data(contentsOf: supportDirectory.appendingPathComponent("rewrite-rules.json")),
           let parsed = try? JSONDecoder().decode([RewriteRule].self, from: rules) { rewriteRules = parsed }
        if let rules = try? Data(contentsOf: supportDirectory.appendingPathComponent("breakpoint-rules.json")),
           let parsed = try? JSONDecoder().decode([BreakpointRule].self, from: rules) { breakpointRules = parsed }
        if let text = try? String(contentsOf: supportDirectory.appendingPathComponent("ssl-hosts.txt"), encoding: .utf8) {
            sslHostsText = text
        }
        if let text = try? String(contentsOf: supportDirectory.appendingPathComponent("trusted-dns-hosts.txt"), encoding: .utf8) {
            trustedDNSHostsText = text
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
            let openedStore = try SessionStore(path: supportDirectory.appendingPathComponent("sessions.sqlite").path)
            store = openedStore
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            try await startEngine(store: openedStore)
            if !sslHostPatterns.isEmpty {
                Task { [weak self] in
                    do { _ = try await self?.ensureAuthority() }
                    catch { self?.errorMessage = error.localizedDescription }
                }
            }
        } catch {
            statusText = "Proxy unavailable"
            errorMessage = error.localizedDescription
        }
    }

    func restart(port: Int) async {
        if systemProxyEnabled {
            do { try proxySettings.restore(); systemProxyEnabled = false; hasPendingRestore = false }
            catch { errorMessage = error.localizedDescription; return }
        }
        await engine?.stop()
        engine = nil
        proxyPort = port
        guard let store else { return }
        do { try await startEngine(store: store) }
        catch { statusText = "Proxy unavailable"; errorMessage = error.localizedDescription }
    }

    private func startEngine(store: SessionStore) async throws {
        let proxy = ProxyEngine(store: store, trustedResolver: GoogleHTTPSDNSResolver(),
                                trustedDNSHosts: Set(trustedDNSHostPatterns))
        await proxy.setRules(rewriteRules)
        await proxy.breakpointCenter.setRules(breakpointRules)
        await proxy.setRecordingEnabled(recordingEnabled)
        if let authority { await proxy.configureTLS(authority: authority, includeHosts: sslHostPatterns) }
        do {
            proxyPort = try await proxy.start(port: proxyPort)
            engine = proxy
            statusText = "Listening on 127.0.0.1:\(proxyPort)"
        } catch {
            await proxy.stop()
            throw error
        }
    }

    private var sslHostPatterns: [String] {
        sslHostsText.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var trustedDNSHostPatterns: [String] {
        trustedDNSHostsText.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    func refresh() async {
        if let store {
            do { summaries = try await store.listSummaries(limit: 1_000) }
            catch { errorMessage = error.localizedDescription }
        }
        if let engine { pendingBreakpoints = await engine.breakpointCenter.pending() }
    }

    func select(_ id: UUID?) async {
        selectedID = id
        guard let id, let store else { selectedTransaction = nil; return }
        do {
            let loaded = try await store.load(id: id)
            if selectedID == id { selectedTransaction = loaded }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func enableSSLForSelectedHost() async {
        guard let host = selectedTransaction.flatMap({ URL(string: $0.request.url)?.host }) else { return }
        await refreshRootCertificateStatus()
        guard rootCertificateStatus == "Trusted for SSL" else {
            errorMessage = "Open HTTPS Setup, export the root certificate, and trust it for SSL in Keychain Access first. Then enable SSL Proxying for \(host) and reload the page."
            return
        }
        var hosts = sslHostPatterns
        if !hosts.contains(host) { hosts.append(host) }
        await updateSSLHosts(hosts.joined(separator: "\n"))
    }

    func refreshRootCertificateStatus() async {
        guard !isCheckingCertificateTrust else { return }
        isCheckingCertificateTrust = true
        rootCertificateStatus = "Checking certificate trust…"
        certificateTrustCheckedAt = nil
        let rootURL = supportDirectory.appendingPathComponent("root-ca.pem")
        rootCertificateStatus = await certificateTrustEvaluator(rootURL)
        certificateTrustCheckedAt = Date()
        isCheckingCertificateTrust = false
    }

    private nonisolated static func evaluateRootCertificate(at rootURL: URL) -> String {
        guard let pem = try? String(contentsOf: rootURL, encoding: .utf8) else {
            return "Not generated — export the root certificate first"
        }
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        guard let bytes = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else {
            return "Root certificate could not be read"
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess,
              let trust else { return "Certificate trust could not be checked" }
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return "Trusted for SSL" }
        return "Not trusted for SSL — import and trust in Keychain Access"
    }

    func toggleRecording() async {
        recordingEnabled.toggle()
        await engine?.setRecordingEnabled(recordingEnabled)
    }

    func toggleSystemProxy() {
        guard engine != nil || systemProxyEnabled else {
            errorMessage = "Start the local proxy before enabling the system proxy."
            return
        }
        do {
            if systemProxyEnabled {
                try proxySettings.restore()
                systemProxyEnabled = false
            } else {
                try proxySettings.enable(port: proxyPort)
                systemProxyEnabled = true
            }
            hasPendingRestore = proxySettings.hasPendingRestore
        } catch { errorMessage = error.localizedDescription }
    }

    func restorePreviousProxy() {
        do {
            try proxySettings.restore()
            hasPendingRestore = false
            systemProxyEnabled = false
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreSystemProxyOnExit() {
        if proxySettings.hasPendingRestore { try? proxySettings.restore() }
    }

    func updateSSLHosts(_ text: String) async {
        sslHostsText = text
        sslSetupInProgress = true
        defer { sslSetupInProgress = false }
        do {
            try text.write(to: supportDirectory.appendingPathComponent("ssl-hosts.txt"), atomically: true, encoding: .utf8)
            if let engine {
                if sslHostPatterns.isEmpty, let authority {
                    await engine.configureTLS(authority: authority, includeHosts: [])
                } else if !sslHostPatterns.isEmpty {
                    let loaded = try await ensureAuthority()
                    await engine.configureTLS(authority: loaded, includeHosts: sslHostPatterns)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func updateTrustedDNSHosts(_ text: String) async {
        trustedDNSHostsText = text
        do {
            try text.write(to: supportDirectory.appendingPathComponent("trusted-dns-hosts.txt"),
                           atomically: true, encoding: .utf8)
            await engine?.setTrustedDNSHosts(Set(trustedDNSHostPatterns))
        } catch { errorMessage = error.localizedDescription }
    }

    private func ensureAuthority() async throws -> CertificateAuthority {
        if let authority { return authority }
        if let authorityTask { return try await authorityTask.value }
        let directory = supportDirectory
        let task = Task.detached(priority: .userInitiated) {
            try CertificateAuthority(persistentDirectory: directory)
        }
        authorityTask = task
        do {
            let loaded = try await task.value
            authority = loaded
            authorityTask = nil
            if let engine { await engine.configureTLS(authority: loaded, includeHosts: sslHostPatterns) }
            return loaded
        } catch {
            authorityTask = nil
            throw error
        }
    }

    func saveRewriteRules(_ rules: [RewriteRule]) async {
        rewriteRules = rules
        do {
            try JSONEncoder().encode(rules).write(to: supportDirectory.appendingPathComponent("rewrite-rules.json"), options: .atomic)
            await engine?.setRules(rules)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveBreakpointRules(_ rules: [BreakpointRule]) async {
        breakpointRules = rules
        do {
            try JSONEncoder().encode(rules).write(to: supportDirectory.appendingPathComponent("breakpoint-rules.json"), options: .atomic)
            await engine?.breakpointCenter.setRules(rules)
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveBreakpoint(_ id: UUID, decision: BreakpointDecision) async {
        await engine?.breakpointCenter.resolve(id: id, decision: decision)
        pendingBreakpoints = await engine?.breakpointCenter.pending() ?? []
    }

    func clearSession() async {
        do {
            try await store?.clear()
            summaries = []
            selectedTransaction = nil
            selectedID = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func exportHAR() async {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ProxyLab.har"
        panel.allowedContentTypes = [.init(filenameExtension: "har")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try HARCodec.encode(try await store.list(limit: 100_000))
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }

    func importHAR() async {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "har")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let records = try HARCodec.decode(Data(contentsOf: url))
            for record in records { try await store.save(record) }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func exportRootCertificate() async {
        let pem: String
        if let stored = try? String(contentsOf: supportDirectory.appendingPathComponent("root-ca.pem"), encoding: .utf8) {
            pem = stored
        } else {
            do { pem = try await ensureAuthority().rootCertificatePEM }
            catch { errorMessage = error.localizedDescription; return }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ProxyLab-Root-CA.pem"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try pem.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }
}
