import SwiftUI
import ProxyLabCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var viewMode = 0
    @State private var search = ""
    @State private var showRewrite = false
    @State private var showBreakpointRules = false
    @State private var showPending = false
    @State private var showSettings = false
    @State private var showCertificateGuide = false
    @State private var confirmClearSession = false

    private var filtered: [TransactionSummary] {
        guard !search.isEmpty else { return model.summaries }
        return model.summaries.filter {
            $0.url.localizedCaseInsensitiveContains(search) ||
            $0.method.localizedCaseInsensitiveContains(search) ||
            String($0.status ?? 0).contains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("View", selection: $viewMode) {
                    Text("Sequence").tag(0)
                    Text("Structure").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(10)
                TextField("Filter URL, method, status", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                if viewMode == 0 {
                    List(filtered) { item in row(item) }
                } else {
                    List {
                        ForEach(Dictionary(grouping: filtered, by: \.host).keys.sorted(), id: \.self) { host in
                            DisclosureGroup(host) {
                                ForEach(filtered.filter { $0.host == host }) { item in row(item) }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 290, ideal: 360)
        } detail: {
            VStack(spacing: 0) {
                if let transaction = model.selectedTransaction {
                    TransactionDetailView(transaction: transaction)
                } else {
                    ContentUnavailableView("Select a request", systemImage: "network",
                                           description: Text("Recorded requests appear in Sequence and Structure."))
                }
                Divider()
                HStack {
                    Circle().fill(model.recordingEnabled ? .red : .gray).frame(width: 8, height: 8)
                    Text(model.statusText)
                    Spacer()
                    Text("\(model.summaries.count) requests")
                    if !model.pendingBreakpoints.isEmpty {
                        Button("\(model.pendingBreakpoints.count) paused") { showPending = true }
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .frame(height: 28)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await model.toggleRecording() } } label: {
                    Label(model.recordingEnabled ? "Pause Recording" : "Record", systemImage: model.recordingEnabled ? "record.circle.fill" : "record.circle")
                }
                .help("Start or pause saving new requests")
                Button { model.toggleSystemProxy() } label: {
                    Label(model.systemProxyEnabled ? "Disable System Proxy" : "Enable System Proxy", systemImage: "network.badge.shield.half.filled")
                }
                .help("Route this Mac's HTTP and HTTPS traffic through ProxyLab")
                Button { showRewrite = true } label: { Label("Rewrite", systemImage: "arrow.left.arrow.right") }
                Button { showBreakpointRules = true } label: { Label("Breakpoints", systemImage: "pause.circle") }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                Menu {
                    Button("Import HAR…") { Task { await model.importHAR() } }
                    Button("Export HAR…") { Task { await model.exportHAR() } }
                    Divider()
                    Button("Clear Session") { confirmClearSession = true }
                    Button("Root Certificate…") { showCertificateGuide = true }
                } label: { Label("File", systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $showRewrite) { RewriteRulesView().environmentObject(model).frame(minWidth: 650, minHeight: 460) }
        .sheet(isPresented: $showBreakpointRules) { BreakpointRulesView().environmentObject(model).frame(minWidth: 540, minHeight: 380) }
        .sheet(isPresented: $showPending) { PendingBreakpointsView().environmentObject(model).frame(minWidth: 760, minHeight: 500) }
        .sheet(isPresented: $showSettings) { ProxySettingsView().environmentObject(model).frame(minWidth: 540, minHeight: 440) }
        .sheet(isPresented: $showCertificateGuide) { CertificateGuideView().environmentObject(model).frame(minWidth: 540, minHeight: 350) }
        .confirmationDialog("Clear all recorded requests?", isPresented: $confirmClearSession) {
            Button("Clear Session", role: .destructive) { Task { await model.clearSession() } }
        } message: {
            Text("This removes the current local session and cannot be undone.")
        }
        .alert("ProxyLab", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.pendingBreakpoints.count) { old, new in
            if new > old && new > 0 { showPending = true }
        }
        .overlay(alignment: .top) {
            if model.hasPendingRestore && !model.systemProxyEnabled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("A previous system proxy setting needs restoration.")
                    Button("Restore") { model.restorePreviousProxy() }
                }
                .padding(8)
                .background(.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            }
        }
    }

    private func row(_ item: TransactionSummary) -> some View {
        Button {
            Task { await model.select(item.id) }
        } label: {
            HStack(spacing: 8) {
                Text(item.method).font(.caption.monospaced()).frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(string: item.url)?.path.isEmpty == false ? (URL(string: item.url)?.path ?? item.url) : item.url)
                        .lineLimit(1)
                    Text(item.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(item.status.map(String.init) ?? "…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle((item.status ?? 200) >= 400 ? .red : .secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selectedID == item.id ? Color.accentColor.opacity(0.16) : Color.clear)
    }
}

private struct TransactionDetailView: View {
    let transaction: CapturedTransaction
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transaction.request.url).font(.headline).textSelection(.enabled)
                HStack {
                    Text(transaction.request.method).font(.caption.monospaced()).bold()
                    if let status = transaction.response?.status { Text("HTTP \(status)") }
                    if transaction.tlsIntercepted { Label("SSL Proxying", systemImage: "lock.shield") }
                    Spacer()
                    Text(transaction.startedAt.formatted(date: .abbreviated, time: .standard))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            Picker("Details", selection: $tab) {
                Text("Overview").tag(0)
                Text("Request").tag(1)
                Text("Response").tag(2)
                Text("Timeline").tag(3)
                Text("SSL").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case 0:
                        section("URL", transaction.request.url)
                        section("Method", transaction.request.method)
                        section("Status", transaction.response.map { String($0.status) } ?? "No response")
                        if let error = transaction.error { section("Error", error) }
                        section("Request bytes retained", "\(transaction.request.body.count)\(transaction.requestBodyTruncated ? " (truncated)" : "")")
                        section("Response bytes retained", "\(transaction.response?.body.count ?? 0)\(transaction.responseBodyTruncated ? " (truncated)" : "")")
                    case 1:
                        section("Headers", formattedHeaders(transaction.request.headers))
                        section("Body", bodyPreview(transaction.request.body))
                    case 2:
                        section("Headers", formattedHeaders(transaction.response?.headers ?? []))
                        section("Body", bodyPreview(transaction.response?.body ?? Data()))
                    case 3:
                        section("Started", transaction.startedAt.formatted(date: .complete, time: .complete))
                        if let end = transaction.endedAt {
                            section("Completed", end.formatted(date: .complete, time: .complete))
                            section("Duration", String(format: "%.1f ms", end.timeIntervalSince(transaction.startedAt) * 1_000))
                        }
                    default:
                        section("TLS inspection", transaction.tlsIntercepted ? "Decrypted with ProxyLab's local CA" : "Not decrypted")
                        section("Certificate pinning", "Apps that pin their server certificate may reject local inspection.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private func section(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func formattedHeaders(_ headers: [HTTPHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    private func bodyPreview(_ data: Data) -> String {
        if data.isEmpty { return "—" }
        let prefix = data.prefix(64 * 1_024)
        if let text = String(data: prefix, encoding: .utf8) {
            return text + (data.count > prefix.count ? "\n… preview limited to 64 KB" : "")
        }
        return prefix.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ") + "\n(binary preview)"
    }
}

private struct ProxySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var hosts = ""
    @State private var port = "8888"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proxy Settings").font(.title2).bold()
            HStack { Text("HTTP proxy port"); TextField("8888", text: $port).frame(width: 85) }
            Text("SSL Proxying locations").font(.headline)
            Text("One hostname or wildcard per line. Empty means HTTPS stays encrypted.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $hosts).font(.system(.body, design: .monospaced))
                .border(.separator).frame(height: 130)
            Text("Export and trust the local root certificate before inspecting HTTPS.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    Task {
                        await model.updateSSLHosts(hosts)
                        if let newPort = Int(port), (1...65535).contains(newPort), newPort != model.proxyPort {
                            await model.restart(port: newPort)
                        }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { hosts = model.sslHostsText; port = String(model.proxyPort) }
    }
}

private struct CertificateGuideView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SSL Proxying Certificate").font(.title2).bold()
            Text("1. Export the ProxyLab root certificate. The private key stays in this Mac's Keychain.")
            Text("2. Open Keychain Access, import the certificate into your login keychain, and explicitly trust it for SSL.")
            Text("3. Add the hostnames you want to inspect in Proxy Settings. Other HTTPS connections remain opaque tunnels.")
            Text("Remove trust in Keychain Access when you no longer need HTTPS inspection.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Export Root Certificate…") { Task { await model.exportRootCertificate() } }
                Button("Open Keychain Access") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app")) }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(22)
    }
}
