import AppKit
import SwiftUI
import ProxyLabCore

struct BodyInspector: View {
    let data: Data
    let contentType: String?
    let contentEncoding: String?
    let truncated: Bool
    let suggestedName: String
    let emptyMessage: String
    var supportsPreview = false
    var responseURL: String? = nil
    @State private var mode = "Decoded"
    @State private var pretty = true
    @State private var decoded = Data()
    @State private var decodeError: String?
    @State private var displayText = ""
    @State private var loading = false
    @State private var preview = BodyPreview.detect(data: Data(), contentType: nil)

    private var chosenBytes: Data { (mode == "Decoded" || mode == "Preview") && decodeError == nil ? decoded : data }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Body format", selection: $mode) {
                    if supportsPreview { Text("Preview").tag("Preview") }
                    Text("Decoded").tag("Decoded")
                    Text("Raw").tag("Raw")
                    Text("Hex").tag("Hex")
                }.pickerStyle(.segmented).labelsHidden().frame(width: supportsPreview ? 285 : 230)
                if mode != "Preview" {
                    Toggle("Format JSON", isOn: $pretty).toggleStyle(.checkbox).disabled(mode == "Hex")
                }
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
            if let decodeError, mode == "Decoded" || mode == "Preview" { Text(decodeError).font(.caption).foregroundStyle(.orange) }
            if loading {
                ProgressView("Loading body…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if data.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "doc.text")
            } else if mode == "Preview", decodeError == nil {
                ResponsePreviewView(data: decoded, preview: preview, contentType: contentType, truncated: truncated)
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
        .task {
            if supportsPreview { mode = "Preview" }
            await decodeBody()
        }
        .task(id: "\(mode)-\(pretty)") { await updateText() }
    }

    private func decodeBody() async {
        loading = true
        let result = await Task.detached {
            Result { try BodyContent.decode(data, contentEncoding: contentEncoding) }
        }.value
        switch result {
        case .success(let bytes):
            decoded = bytes
            decodeError = nil
            preview = BodyPreview.detect(data: bytes, contentType: contentType, url: responseURL)
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
        let ext = (mode == "Decoded" || mode == "Preview") && decodeError == nil ? preview.fileExtension : "bin"
        panel.nameFieldStringValue = suggestedName + "." + ext
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
