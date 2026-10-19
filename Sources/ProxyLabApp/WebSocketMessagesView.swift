import SwiftUI
import ProxyLabCore

struct WebSocketMessagesView: View {
    let page: WebSocketMessagePage
    private var messages: [WebSocketMessage] { page.messages }
    private let previewLimit = 256 * 1_024

    init(page: WebSocketMessagePage) { self.page = page }
    init(messages: [WebSocketMessage]) { page = WebSocketMessagePage(messages: messages, totalCount: messages.count) }
    @State private var selectedID: UUID?
    @State private var format = PayloadFormat.decoded

    private enum PayloadFormat: String, CaseIterable {
        case decoded = "Decoded"
        case hex = "Hex"
    }
    private var selected: WebSocketMessage? { messages.first { $0.id == selectedID } ?? messages.last }

    var body: some View {
        if messages.isEmpty {
            ContentUnavailableView("No WebSocket messages", systemImage: "arrow.left.arrow.right", description: Text("Messages appear here while this connection is active."))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if page.isLimited {
                    Label("Showing the latest \(messages.count.formatted()) of \(page.totalCount.formatted()) messages.", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                VSplitView {
                    Table(messages, selection: $selectedID) {
                        TableColumn("Direction") { message in
                            Label(message.direction.label, systemImage: message.direction == .clientToServer ? "arrow.up" : "arrow.down")
                        }.width(min: 135, ideal: 165)
                        TableColumn("Time") { message in
                            Text(message.timestamp.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                                .monospacedDigit()
                        }.width(min: 95, ideal: 110)
                        TableColumn("Opcode") { message in Text(message.opcode.label).font(.caption.monospaced()) }.width(65)
                        TableColumn("Bytes") { message in Text(message.payloadLength.formatted()).monospacedDigit() }.width(65)
                        TableColumn("Payload") { message in
                            Text(preview(message)).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 160)
                    if let selected {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(selected.direction.label) · \(selected.opcode.label) · \(selected.payloadLength.formatted()) bytes")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Picker("Payload", selection: $format) {
                                    ForEach(PayloadFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.pickerStyle(.segmented).frame(width: 170)
                            }
                            if selected.isTruncated || selected.payload.count > previewLimit {
                                Label("Showing the first \(min(selected.payload.count, previewLimit).formatted()) of \(selected.payloadLength.formatted()) bytes", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            ScrollView {
                                Text(format == .hex ? selected.hexPreview(maxBytes: previewLimit) : decoded(selected))
                                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(12).frame(minHeight: 180)
                    }
                }
            }
        }
    }

    private func preview(_ message: WebSocketMessage) -> String {
        if message.opcode == .close { return decoded(message) }
        if let text = String(data: message.payload.prefix(200), encoding: .utf8) { return text }
        return message.payload.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func decoded(_ message: WebSocketMessage) -> String {
        let payload = message.previewPayload(maxBytes: previewLimit)
        if message.opcode == .close, payload.count >= 2 {
            let bytes = Array(payload.prefix(2))
            let code = Int(bytes[0]) << 8 | Int(bytes[1])
            let reason = String(data: payload.dropFirst(2), encoding: .utf8) ?? ""
            return "Close \(code)\(reason.isEmpty ? "" : ": \(reason)")"
        }
        guard let text = message.decodedPreview(maxBytes: previewLimit) else { return "This payload is not UTF-8 text. Select Hex to inspect its bytes." }
        if message.opcode == .text, payload.count == message.payloadLength, let object = try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed),
           let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let json = String(data: formatted, encoding: .utf8) { return json }
        return text
    }
}
