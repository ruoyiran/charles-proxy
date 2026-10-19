import Foundation
import UniformTypeIdentifiers

public enum BodyPreviewKind: String, Sendable {
    case json = "JSON", text = "Text", html = "HTML", image = "Image"
    case pdf = "PDF", audio = "Audio", video = "Video", binary = "Binary"
}

public struct BodyPreview: Sendable {
    public let kind: BodyPreviewKind
    public let fileExtension: String

    public static func detect(data: Data, contentType: String?, url: String? = nil) -> BodyPreview {
        let mime = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !mime.isEmpty, mime != "application/octet-stream", mime != "binary/octet-stream" {
            return forMIME(mime)
        }
        let bytes = Array(data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]) { return .init(kind: .image, fileExtension: "png") }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return .init(kind: .image, fileExtension: "jpg") }
        if bytes.starts(with: Array("GIF8".utf8)) { return .init(kind: .image, fileExtension: "gif") }
        if bytes.starts(with: Array("%PDF-".utf8)) { return .init(kind: .pdf, fileExtension: "pdf") }
        if bytes.starts(with: Array("RIFF".utf8)), bytes.count >= 12,
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return .init(kind: .image, fileExtension: "webp") }
        if bytes.starts(with: Array("PK\u{3}\u{4}".utf8)) { return .init(kind: .binary, fileExtension: "zip") }
        if let ext = url.flatMap({ URL(string: $0)?.pathExtension.lowercased() }),
           !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            let preview = forMIME(mime)
            if preview.kind != .binary { return preview }
        }
        let sample = data.prefix(4096)
        if !sample.isEmpty, !sample.contains(0), let text = String(data: sample, encoding: .utf8) {
            let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.hasPrefix("<svg") {
                return .init(kind: .html, fileExtension: lower.hasPrefix("<svg") ? "svg" : "html")
            }
            if (lower.hasPrefix("{") || lower.hasPrefix("[")),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return .init(kind: .json, fileExtension: "json")
            }
            return .init(kind: .text, fileExtension: "txt")
        }
        return .init(kind: .binary, fileExtension: "bin")
    }

    private static func forMIME(_ mime: String) -> BodyPreview {
        let ext = UTType(mimeType: mime)?.preferredFilenameExtension
        if mime == "application/json" || mime.hasSuffix("+json") { return .init(kind: .json, fileExtension: "json") }
        if mime == "text/html" || mime == "application/xhtml+xml" { return .init(kind: .html, fileExtension: "html") }
        if mime == "image/svg+xml" { return .init(kind: .html, fileExtension: "svg") }
        if mime.hasPrefix("image/") { return .init(kind: .image, fileExtension: ext ?? "img") }
        if mime == "application/pdf" { return .init(kind: .pdf, fileExtension: "pdf") }
        if mime.hasPrefix("audio/") { return .init(kind: .audio, fileExtension: ext ?? "audio") }
        if mime.hasPrefix("video/") { return .init(kind: .video, fileExtension: ext ?? "video") }
        if mime == "application/xml" || mime == "text/xml" || mime.hasSuffix("+xml") {
            return .init(kind: .text, fileExtension: "xml")
        }
        if mime.contains("javascript") || mime.contains("ecmascript") { return .init(kind: .text, fileExtension: "js") }
        if mime.hasPrefix("text/") || mime == "application/x-www-form-urlencoded" {
            return .init(kind: .text, fileExtension: ext ?? "txt")
        }
        return .init(kind: .binary, fileExtension: ext ?? "bin")
    }
}
