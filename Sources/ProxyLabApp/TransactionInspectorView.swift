import AppKit
import SwiftUI
import ProxyLabCore

struct TransactionInspectorView: View {
    let transaction: CapturedTransaction
    let showCertificateGuide: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = InspectorTab.overview

    private enum InspectorTab: String, CaseIterable {
        case overview = "Overview"
        case requestHeaders = "Request Headers"
        case requestBody = "Request Body"
        case responseHeaders = "Response Headers"
        case responseBody = "Response Body"
        case webSocket = "WebSocket"
    }

    private var isTunnel: Bool { transaction.request.method.uppercased() == "CONNECT" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(transaction.request.url).font(.headline).textSelection(.enabled)
                HStack {
                    MethodBadge(method: transaction.request.method)
                    if let status = transaction.response?.status {
                        if isTunnel { Text("Tunnel established") }
                        StatusBadge(status: status)
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
                    Text("This record contains an earlier CONNECT tunnel only. ProxyLab now inspects all HTTPS hosts. Trust the root certificate and reload the page to create a new decrypted request. Earlier tunnel records cannot be decrypted retrospectively.")
                        .font(.callout)
                    Button("HTTPS Setup…", action: showCertificateGuide)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
            }
            Picker("Inspector", selection: $selectedTab) {
                ForEach(InspectorTab.allCases.filter { $0 != .webSocket || transaction.response?.status == 101 || selectedTab == .webSocket }, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Group {
                switch selectedTab {
                case .overview: overview
                case .requestHeaders:
                    HeadersInspector(headers: transaction.request.headers)
                case .responseHeaders:
                    HeadersInspector(headers: (transaction.response?.headers ?? []) + (transaction.responseTrailers ?? []))
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
                                  suggestedName: "response-body", emptyMessage: isTunnel ? "HTTPS content has not been decrypted." : "This response has no body.",
                                  supportsPreview: true, responseURL: transaction.request.url)
                case .webSocket:
                    if transaction.response?.status == 101 {
                        WebSocketMessagesView(page: model.webSocketPage)
                    } else {
                        ContentUnavailableView("This request is not a WebSocket", systemImage: "network")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(transaction.id)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                property("URL", transaction.request.url)
                property("Method", transaction.request.method)
                if let version = transaction.requestHTTPVersion { property("Client HTTP version", version) }
                if let version = transaction.responseHTTPVersion { property("Upstream HTTP version", version) }
                if let id = transaction.replayOf { property("Replayed from", id.uuidString) }
                if let address = transaction.clientAddress { property("Client device", address) }
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
