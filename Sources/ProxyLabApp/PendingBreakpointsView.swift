import SwiftUI
import ProxyLabCore

struct PendingBreakpointsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var method = ""
    @State private var url = ""
    @State private var status = "200"
    @State private var headers = ""
    @State private var bodyText = ""
    @State private var binaryBody = false

    private var selected: PendingBreakpoint? {
        model.pendingBreakpoints.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                Text("Paused Traffic").font(.headline).padding(12)
                List(model.pendingBreakpoints) { item in
                    Button {
                        selectedID = item.id
                        load(item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(item.phase.rawValue.capitalized) · \(item.request.method)").bold()
                            Text(item.request.url).font(.caption).lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(item.id == selectedID ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .frame(width: 240)
            }
            Divider()
            if let item = selected {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.phase == .request ? "Edit Request" : "Edit Response").font(.title3).bold()
                    if item.phase == .request {
                        HStack { TextField("Method", text: $method).frame(width: 90); TextField("URL", text: $url) }
                    } else {
                        HStack { Text("Status"); TextField("Status", text: $status).frame(width: 85) }
                    }
                    Text("Headers").font(.caption).bold()
                    TextEditor(text: $headers).font(.system(.body, design: .monospaced)).border(.separator).frame(height: 130)
                    Text("Body").font(.caption).bold()
                    TextEditor(text: $bodyText).font(.system(.body, design: .monospaced))
                        .border(.separator).disabled(binaryBody || item.bodyTruncated)
                    if binaryBody { Text("Binary body is shown without text editing.").font(.caption).foregroundStyle(.secondary) }
                    if item.bodyTruncated {
                        Text("Only the first 10 MB is shown. This body cannot be edited; header changes still apply.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Execute") { resolve(item, as: .execute(request: nil, response: nil)) }
                            .keyboardShortcut(.defaultAction)
                        Button("Cancel Changes") { resolve(item, as: .cancel) }
                        Button("Abort", role: .destructive) { resolve(item, as: .abort) }
                        Spacer()
                        Button("Close") { dismiss() }
                    }
                }
                .padding(16)
            } else {
                ContentUnavailableView("No paused requests", systemImage: "play.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let first = model.pendingBreakpoints.first { selectedID = first.id; load(first) }
        }
        .onChange(of: model.pendingBreakpoints.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? UUID()), let first = model.pendingBreakpoints.first {
                selectedID = first.id
                load(first)
            }
        }
    }

    private func load(_ item: PendingBreakpoint) {
        method = item.request.method
        url = item.request.url
        status = String(item.response?.status ?? 200)
        let chosenHeaders = item.phase == .request ? item.request.headers : (item.response?.headers ?? [])
        headers = chosenHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        let chosenBody = item.phase == .request ? item.request.body : (item.response?.body ?? Data())
        binaryBody = !chosenBody.isEmpty && String(data: chosenBody, encoding: .utf8) == nil
        bodyText = String(data: chosenBody, encoding: .utf8) ?? ""
    }

    private func resolve(_ item: PendingBreakpoint, as decision: BreakpointDecision) {
        let resolved: BreakpointDecision
        if case .execute = decision {
            let parsedHeaders: [HTTPHeader] = headers.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return HTTPHeader(name: String(parts[0]).trimmingCharacters(in: .whitespaces),
                                  value: String(parts[1]).trimmingCharacters(in: .whitespaces))
            }
            if item.phase == .request {
                var request = item.request
                request.method = method
                request.url = url
                request.headers = parsedHeaders
                if !binaryBody { request.body = Data(bodyText.utf8) }
                resolved = .execute(request: request, response: nil)
            } else {
                var response = item.response ?? ProxyResponse(status: 200)
                response.status = Int(status) ?? response.status
                response.headers = parsedHeaders
                if !binaryBody && !item.bodyTruncated { response.body = Data(bodyText.utf8) }
                resolved = .execute(request: nil, response: response)
            }
        } else { resolved = decision }
        Task { await model.resolveBreakpoint(item.id, decision: resolved) }
    }
}
