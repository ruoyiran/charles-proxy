import AppKit
import ProxyLabCore
import SwiftUI

struct RequestComposerView: View {
    let transaction: CapturedTransaction?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var method = "GET"
    @State private var url = "https://example.com/"
    @State private var headers = ""
    @State private var text = ""
    @State private var bytes = Data()
    @State private var binary = false
    @State private var hasCompleteBody = true
    @State private var changedText = false
    @State private var initializing = true
    @State private var bodyFromFile = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(transaction == nil ? "Compose Request" : "Edit and Send").font(.title2.bold())
            HStack { TextField("Method", text: $method).frame(width: 95); TextField("URL", text: $url) }
            Text("Headers").font(.headline)
            TextEditor(text: $headers).font(.body.monospaced()).border(.separator).frame(height: 150)
                .accessibilityLabel("Request headers editor")
            HStack {
                Text("Body").font(.headline)
                Spacer()
                Text("\(binary ? bytes.count : text.utf8.count) bytes").font(.caption).foregroundStyle(.secondary)
                Button("Load Body File…") { loadFile() }
                Button("Clear Body") { bytes = Data(); text = ""; binary = false; hasCompleteBody = true; changedText = true; bodyFromFile = false }
            }
            if binary {
                Text("Binary body retained. Load a file to replace it.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: .constant(BodyContent.hex(Data(bytes.prefix(4096))))).font(.body.monospaced()).border(.separator)
            } else {
                TextEditor(text: $text).font(.body.monospaced()).border(.separator).accessibilityLabel("Request body editor")
                    .onChange(of: text) { _, _ in if !initializing { changedText = true } }
            }
            if !hasCompleteBody { Text("The original body is truncated. Load a complete file or replace the body before sending.").foregroundStyle(.orange).font(.caption) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Text("The result appears as a new request in ProxyLab. Host, Content-Length and proxy-only headers are normalized before sending.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.cancelSend(); dismiss() }
                Spacer()
                if model.sendingRequest { ProgressView().controlSize(.small); Button("Stop") { model.cancelSend() } }
                Button("Send") { send() }.disabled(model.sendingRequest || (!hasCompleteBody && !changedText))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 780, height: 600)
        .onAppear {
            if let transaction {
                method = transaction.request.method; url = transaction.request.url
                headers = transaction.request.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                bytes = transaction.request.body
                binary = !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil
                text = String(data: bytes, encoding: .utf8) ?? ""
                hasCompleteBody = !transaction.requestBodyTruncated
                changedText = false
            }
            Task { await Task.yield(); initializing = false }
        }
    }

    private func loadFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 10 * 1024 * 1024 else { error = "Body files must be at most 10 MB."; return }
            bytes = data; binary = true
            text = ""; hasCompleteBody = true; changedText = true; bodyFromFile = true
        } catch { self.error = error.localizedDescription }
    }

    private func send() {
        do {
            guard hasCompleteBody || changedText else { throw RequestComposerError.incompleteBody }
            var parsed = try RequestComposer.headers(from: headers)
            if changedText && !bodyFromFile { parsed.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame } }
            let request = try RequestComposer.normalized(.init(method: method, url: url, headers: parsed,
                                                               body: binary ? bytes : Data(text.utf8)))
            error = nil
            Task { if await model.sendRequest(request, replayOf: transaction?.id) { dismiss() } }
        } catch { self.error = error.localizedDescription }
    }
}
