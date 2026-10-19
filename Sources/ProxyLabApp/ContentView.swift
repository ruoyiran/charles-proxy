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
    @State private var requestToDelete: UUID?

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
                HStack {
                    Text("\(filtered.count) requests").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { confirmClearSession = true } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(model.summaries.isEmpty)
                    .help("Clear all recorded requests")
                    .accessibilityLabel("Clear Requests")
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
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
                    TransactionInspectorView(transaction: transaction,
                                             showCertificateGuide: { showCertificateGuide = true })
                } else {
                    ContentUnavailableView("Select a request", systemImage: "network",
                                           description: Text("Recorded requests appear in Sequence and Structure."))
                }
                Divider()
                HStack {
                    Circle().fill(model.recordingEnabled ? .red : .gray).frame(width: 8, height: 8)
                    Text(model.statusText)
                    if model.proxyUnavailable {
                        Button("Retry") { Task { await model.start() } }
                    }
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
                Button { showCertificateGuide = true } label: { Label("HTTPS Setup", systemImage: "lock.shield") }
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
        .sheet(isPresented: $showSettings) { ProxySettingsView().environmentObject(model).frame(minWidth: 540, minHeight: 430) }
        .sheet(isPresented: $showCertificateGuide) { CertificateGuideView().environmentObject(model).frame(minWidth: 600, minHeight: 400) }
        .confirmationDialog("Clear all recorded requests?", isPresented: $confirmClearSession) {
            Button("Clear Session", role: .destructive) { Task { await model.clearSession() } }
        } message: {
            Text("This removes the current local session and cannot be undone.")
        }
        .confirmationDialog("Delete this recorded request?", isPresented: Binding(
            get: { requestToDelete != nil }, set: { if !$0 { requestToDelete = nil } }
        )) {
            Button("Delete Request", role: .destructive) {
                if let id = requestToDelete { Task { await model.deleteRequest(id) } }
                requestToDelete = nil
            }
        } message: {
            Text("The saved headers and bodies for this request will be removed.")
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
                MethodBadge(method: item.method)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(string: item.url)?.path.isEmpty == false ? (URL(string: item.url)?.path ?? item.url) : item.url)
                        .lineLimit(1)
                    Text(item.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                StatusBadge(status: item.status)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selectedID == item.id ? Color.accentColor.opacity(0.16) : Color.clear)
        .contextMenu {
            Button("Delete Request", role: .destructive) { requestToDelete = item.id }
            Button("Clear All Requests", role: .destructive) { confirmClearSession = true }
        }
    }
}

private struct ProxySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var trustedDNSHosts = ""
    @State private var port = "8888"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proxy Settings").font(.title2).bold()
            HStack { Text("HTTP proxy port"); TextField("8888", text: $port).frame(width: 85) }
            Text("HTTPS inspection").font(.headline)
            CertificateTrustStatusView()
            Text("HTTPS inspection is enabled for all hosts. Trust the ProxyLab root certificate to view request and response headers and bodies.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Trusted DNS routing").font(.headline)
            Text("For hosts whose local DNS points to a blocked or incorrect address. One hostname per line. ProxyLab resolves these names through dns.google while keeping the original TLS hostname.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $trustedDNSHosts).font(.system(.body, design: .monospaced))
                .border(.separator).frame(height: 75)
            Text("Export and trust the local root certificate before inspecting HTTPS.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    Task {
                        await model.updateTrustedDNSHosts(trustedDNSHosts)
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
        .onAppear {
            trustedDNSHosts = model.trustedDNSHostsText
            port = String(model.proxyPort)
        }
        .task { await model.refreshRootCertificateStatus() }
    }
}

private struct CertificateGuideView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SSL Proxying Certificate").font(.title2).bold()
            CertificateTrustStatusView()
            Text("1. Export the ProxyLab root certificate. The private key stays in this Mac's Keychain.")
            Text("2. Open Keychain Access, import the certificate into your login keychain, and explicitly trust it for SSL.")
            Text("3. Reload the browser page. ProxyLab inspects all HTTPS hosts automatically; no hostname configuration is needed.")
            Text("Apps that pin certificates may reject HTTPS inspection.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Remove trust in Keychain Access when you no longer need HTTPS inspection.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Export Root Certificate…") { Task { await model.exportRootCertificate() } }
                Button("Open Keychain Access") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app")) }
                Spacer()
                Button("Done") { dismiss() }
            }
            Button("Check Certificate Trust Again") { Task { await model.refreshRootCertificateStatus() } }
                .disabled(model.isCheckingCertificateTrust)
        }
        .padding(22)
        .task { await model.refreshRootCertificateStatus() }
    }
}

private struct CertificateTrustStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if model.isCheckingCertificateTrust {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.rootCertificateStatus == "Trusted for SSL" ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.rootCertificateStatus == "Trusted for SSL" ? .green : .orange)
                }
                Text(model.rootCertificateStatus)
            }
            .font(.callout)
            if let checkedAt = model.certificateTrustCheckedAt {
                Text("Check completed at \(checkedAt.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
