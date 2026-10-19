import Foundation
import NIOCore
import NIOWebSocket

public enum WebSocketDirection: String, Codable, CaseIterable, Sendable {
    case clientToServer, serverToClient
    public var label: String { self == .clientToServer ? "Client → Server" : "Server → Client" }
}

public enum WebSocketMessageOpcode: String, Codable, Sendable {
    case text, binary, ping, pong, close
    public var label: String { rawValue.uppercased() }
}

public struct WebSocketMessage: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var direction: WebSocketDirection
    public var timestamp: Date
    public var opcode: WebSocketMessageOpcode
    public var payload: Data
    public var payloadLength: Int
    public var isTruncated: Bool

    public init(id: UUID = UUID(), direction: WebSocketDirection, timestamp: Date = Date(),
                opcode: WebSocketMessageOpcode, payload: Data, payloadLength: Int? = nil, isTruncated: Bool = false) {
        self.id = id
        self.direction = direction
        self.timestamp = timestamp
        self.opcode = opcode
        self.payload = payload
        self.payloadLength = payloadLength ?? payload.count
        self.isTruncated = isTruncated
    }

    public var decodedText: String? { String(data: payload, encoding: .utf8) }
    public var hexText: String { payload.map { String(format: "%02X", $0) }.joined(separator: " ") }

    public func previewPayload(maxBytes: Int = 256 * 1_024) -> Data { Data(payload.prefix(max(0, min(maxBytes, 256 * 1_024)))) }
    public func decodedPreview(maxBytes: Int = 256 * 1_024) -> String? {
        let preview = previewPayload(maxBytes: maxBytes)
        if let text = String(data: preview, encoding: .utf8) { return text }
        guard preview.count < payload.count else { return nil }
        // A bounded prefix may stop within the final UTF-8 scalar; trim only its partial bytes.
        for omitted in 1...min(3, preview.count) {
            if let text = String(data: preview.dropLast(omitted), encoding: .utf8) { return text }
        }
        return nil
    }
    public func hexPreview(maxBytes: Int = 256 * 1_024) -> String {
        previewPayload(maxBytes: maxBytes).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

public struct WebSocketMessagePage: Sendable, Equatable {
    public var messages: [WebSocketMessage]
    public var totalCount: Int
    public var isLimited: Bool
    public static let empty = WebSocketMessagePage()

    public init(messages: [WebSocketMessage] = [], totalCount: Int = 0, isLimited: Bool = false) {
        self.messages = messages
        self.totalCount = totalCount
        self.isLimited = isLimited
    }
}

enum WebSocketCaptureError: Error { case invalidFrame, invalidUTF8, messageTooLarge }

/// Retains a bounded prefix while validating fragmentation and UTF-8 across every incoming frame.
struct WebSocketMessageAssembler {
    let direction: WebSocketDirection
    let captureLimit: Int
    private var opcode: WebSocketMessageOpcode?
    private var started = Date()
    private var payload = Data()
    private var length = 0
    private var utf8 = WebSocketUTF8Validator()

    init(direction: WebSocketDirection, captureLimit: Int = 1_048_576) {
        self.direction = direction
        self.captureLimit = max(0, captureLimit)
    }

    mutating func receive(_ frame: WebSocketFrame) throws -> WebSocketMessage? {
        guard !frame.rsv1 && !frame.rsv2 && !frame.rsv3, frame.extensionData?.readableBytes ?? 0 == 0 else {
            throw WebSocketCaptureError.invalidFrame
        }
        let bytes = frame.unmaskedData.readableBytesView
        switch frame.opcode {
        case .ping, .pong, .connectionClose:
            guard frame.fin, bytes.count <= 125 else { throw WebSocketCaptureError.invalidFrame }
            let kind: WebSocketMessageOpcode = frame.opcode == .ping ? .ping : (frame.opcode == .pong ? .pong : .close)
            if kind == .close { try validateClose(bytes) }
            return WebSocketMessage(direction: direction, opcode: kind, payload: Data(bytes))
        case .text, .binary:
            guard opcode == nil else { throw WebSocketCaptureError.invalidFrame }
            opcode = frame.opcode == .text ? .text : .binary
            started = Date()
            payload.removeAll(keepingCapacity: true)
            length = 0
            utf8 = WebSocketUTF8Validator()
        case .continuation:
            guard opcode != nil else { throw WebSocketCaptureError.invalidFrame }
        default:
            throw WebSocketCaptureError.invalidFrame
        }
        let (newLength, overflow) = length.addingReportingOverflow(bytes.count)
        guard !overflow else { throw WebSocketCaptureError.messageTooLarge }
        length = newLength
        if opcode == .text { try utf8.append(bytes) }
        payload.append(contentsOf: bytes.prefix(max(0, captureLimit - payload.count)))
        guard frame.fin, let opcode else { return nil }
        if opcode == .text && !utf8.isComplete { throw WebSocketCaptureError.invalidUTF8 }
        let message = WebSocketMessage(direction: direction, timestamp: started, opcode: opcode,
                                       payload: payload, payloadLength: length, isTruncated: length > payload.count)
        self.opcode = nil
        payload = Data()
        return message
    }

    private func validateClose(_ bytes: ByteBufferView) throws {
        guard bytes.count != 1 else { throw WebSocketCaptureError.invalidFrame }
        guard bytes.count >= 2 else { return }
        let values = Array(bytes)
        let code = Int(values[0]) << 8 | Int(values[1])
        guard (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000...4999).contains(code) else {
            throw WebSocketCaptureError.invalidFrame
        }
        var validator = WebSocketUTF8Validator()
        try validator.append(values.dropFirst(2))
        guard validator.isComplete else { throw WebSocketCaptureError.invalidUTF8 }
    }
}

private struct WebSocketUTF8Validator {
    private var remaining = 0
    private var lower: UInt8 = 0x80
    private var upper: UInt8 = 0xBF
    var isComplete: Bool { remaining == 0 }

    mutating func append<S: Sequence>(_ bytes: S) throws where S.Element == UInt8 {
        for byte in bytes {
            if remaining > 0 {
                guard byte >= lower && byte <= upper else { throw WebSocketCaptureError.invalidUTF8 }
                remaining -= 1
                lower = 0x80
                upper = 0xBF
            } else {
                switch byte {
                case 0...0x7F: break
                case 0xC2...0xDF: remaining = 1
                case 0xE0: remaining = 2; lower = 0xA0
                case 0xE1...0xEC, 0xEE...0xEF: remaining = 2
                case 0xED: remaining = 2; upper = 0x9F
                case 0xF0: remaining = 3; lower = 0x90
                case 0xF1...0xF3: remaining = 3
                case 0xF4: remaining = 3; upper = 0x8F
                default: throw WebSocketCaptureError.invalidUTF8
                }
            }
        }
    }
}
