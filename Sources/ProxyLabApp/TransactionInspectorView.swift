import AppKit
import SwiftUI
import ProxyLabCore

struct TransactionInspectorView: View {
    let transaction: CapturedTransaction
    let showSSLSettings: () -> Void
    let showCertificateGuide: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = InspectorTab.overview

    private enum InspectorTab: String, CaseIterable {
        case overview = "Overview"
        case requestHeaders = "Request Headers"
        case requestBody = "Request Body"
        case responseHeaders = "Response Headers"
        case responseBody = "Response Body"
    }

    private var isTunnel: Bool { transaction.request.method.uppercased() == "CONNECT" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(transaction.request.url).font(.headline).textSelection(.enabled)
                HStack {
                    Text(transaction.request.method).font(.caption.monospaced()).bold()
                    if let status = transaction.response?.status {
                        Text(isTunnel ? "Tunnel established (\(status))" : "HTTP \(status)")
                    }
                    if transaction.tlsIntercepted { Label("HTTPS decrypted", systemImage: "lock.open") }
                    Spacer()
                    Text(transaction.startedAt.formatted(date: .omitted, time: .standard))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            if isTunnel {
                VStack(alignment: .leading, spacing: 8) {
                    Label("This connection is encrypted", systemImage: "lock.fill").font(.headline)
                    Text("This record contains the CONNECT tunnel only. Trust the ProxyLab root certificate, enable SSL Proxying for this host, then reload the page to capture its headers and bodies.")
                        .font(.callout)
                    HStack {
                        Button("HTTPS Setup…", action: showCertificateGuide)
                        Button("Enable SSL Proxying for This Host") {
                            Task { await model.enableSSLForSelectedHost() }
                        }
                        .disabled(model.sslSetupInProgress)
                        if model.sslSetupInProgress { ProgressView().controlSize(.small) }
                        Button("SSL Settings…", action: showSSLSettings)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
            }
            Picker("Inspector", selection: $selectedTab) {
                ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Group {
                switch selectedTab {
                case .overview: overview
                case .requestHeaders:
                    HeadersInspector(headers: transaction.request.headers)
                case .responseHeaders:
                    HeadersInspector(headers: transaction.response?.headers ?? [])
                case .requestBody:
                    BodyInspector(data: transaction.request.body,
                                  contentType: transaction.request.header("Content-Type"),
                                  contentEncoding: transaction.request.header("Content-Encoding"),
                                  truncated: transaction.requestBodyTruncated,
                                  suggestedName: "request-body", emptyMessage: isTunnel ? "HTTPS content has not been decrypted." : "This request has no body.")
                case .responseBody:
                    BodyInspector(data: transaction.response?.body ?? Data(),
                                  contentType: transaction.response?.header("Content-Type"),
                                  contentEncoding: transaction.response?.header("Content-Encoding"),
                                  truncated: transaction.responseBodyTruncated,
                                  suggestedName: "response-body", emptyMessage: isTunnel ? "HTTPS content has not been decrypted." : "This response has no body.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                property("URL", transaction.request.url)
                property("Method", transaction.request.method)
                property("Request body retained", "\(transaction.request.body.count) bytes\(transaction.requestBodyTruncated ? " — truncated at 10 MB" : "")")
                property("Response body retained", "\(transaction.response?.body.count ?? 0) bytes\(transaction.responseBodyTruncated ? " — truncated at 10 MB" : "")")
                if let error = transaction.error { property("Error", error) }
                if let end = transaction.endedAt {
                    property("Duration", String(format: "%.1f ms", end.timeIntervalSince(transaction.startedAt) * 1_000))
                }
                property("HTTPS", transaction.tlsIntercepted ? "Decrypted — request and response content is available" : (isTunnel ? "Encrypted tunnel" : "Plain HTTP or imported session"))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }

    private func property(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption).bold().foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

private struct HeadersInspector: View {
    let headers: [HTTPHeader]
    private struct HeaderRow: Identifiable {
        let id: Int
        let name: String
        let value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(headers.count) headers").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Headers") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"), forType: .string)
                }.disabled(headers.isEmpty)
            }.padding(.horizontal, 12).padding(.bottom, 8)
            if headers.isEmpty {
                ContentUnavailableView("No headers captured", systemImage: "list.bullet.rectangle")
            } else {
                Table(headers.enumerated().map { HeaderRow(id: $0.offset, name: $0.element.name, value: $0.element.value) }) {
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                        .width(min: 120, ideal: 190, max: 260)
                    TableColumn("Value") { Text($0.value).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
            }
        }
    }
}

private struct BodyInspector: View {
    let data: Data
    let contentType: String?
    let contentEncoding: String?
    let truncated: Bool
    let suggestedName: String
    let emptyMessage: String
    @State private var mode = "Decoded"
    @State private var pretty = true
    @State private var decoded = Data()
    @State private var decodeError: String?
    @State private var displayText = ""
    @State private var loading = false

    private var chosenBytes: Data { mode == "Decoded" && decodeError == nil ? decoded : data }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Body format", selection: $mode) {
                    Text("Decoded").tag("Decoded")
                    Text("Raw").tag("Raw")
                    Text("Hex").tag("Hex")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Toggle("Format JSON", isOn: $pretty).toggleStyle(.checkbox).disabled(mode == "Hex")
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mode == "Hex" ? BodyContent.hex(chosenBytes) : BodyContent.text(chosenBytes, contentType: contentType, pretty: pretty), forType: .string)
                }.disabled(data.isEmpty || loading)
                Button("Save Body…") { saveBody() }.disabled(data.isEmpty || loading)
            }
            Text("\(data.count) captured bytes · \(contentType ?? "unknown content type") · encoding: \(contentEncoding ?? "identity")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if truncated { Text("Only the first 10 MB was recorded; saved data is also truncated.").font(.caption).foregroundStyle(.orange) }
            if let decodeError, mode == "Decoded" { Text(decodeError).font(.caption).foregroundStyle(.orange) }
            if loading {
                ProgressView("Loading body…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if data.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "doc.text")
            } else {
                TextEditor(text: .constant(displayText))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Body content")
                if chosenBytes.count > 256 * 1_024 {
                    Text("Preview limited to 256 KB. Copy or Save Body includes all retained bytes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
        .task { await decodeBody() }
        .task(id: "\(mode)-\(pretty)") { await updateText() }
    }

    private func decodeBody() async {
        loading = true
        let result = await Task.detached {
            Result { try BodyContent.decode(data, contentEncoding: contentEncoding) }
        }.value
        switch result {
        case .success(let bytes): decoded = bytes; decodeError = nil
        case .failure(let error): decoded = data; decodeError = error.localizedDescription
        }
        await updateText()
        loading = false
    }

    private func updateText() async {
        let bytes = chosenBytes
        let selectedMode = mode
        let formatJSON = pretty
        let type = contentType
        let text = await Task.detached {
            if selectedMode == "Hex" { return BodyContent.hex(Data(bytes.prefix(256 * 1_024))) }
            return String(BodyContent.text(bytes, contentType: type, pretty: formatJSON).prefix(256 * 1_024))
        }.value
        guard !Task.isCancelled else { return }
        displayText = text
    }

    private func saveBody() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try chosenBytes.write(to: url, options: .atomic) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Body could not be saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
