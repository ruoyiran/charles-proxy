import Foundation
import CoreFoundation
import Compression
import CBodyCodec

public enum BodyContentError: LocalizedError {
    case invalidCompressedData, outputLimit, unsupportedEncoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCompressedData: "The compressed body is incomplete or invalid. Raw bytes are still available."
        case .outputLimit: "Decoded body exceeds the 10 MB display limit. Raw bytes are still available."
        case .unsupportedEncoding(let value): "Content-Encoding '\(value)' is not supported. Raw bytes are still available."
        }
    }
}

public enum BodyContent {
    public static func decode(_ data: Data, contentEncoding: String?, limit: Int = 10 * 1_024 * 1_024) throws -> Data {
        guard !data.isEmpty else { return data }
        guard limit > 0, limit < Int(UInt32.max) else { throw BodyContentError.outputLimit }
        let encodings = (contentEncoding ?? "identity").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var decoded = data
        for encoding in encodings.reversed() {
            switch encoding {
            case "", "identity": break
            case "gzip", "x-gzip": decoded = try inflate(decoded, windowBits: 31, limit: limit)
            case "deflate":
                do { decoded = try inflate(decoded, windowBits: 15, limit: limit) }
                catch BodyContentError.invalidCompressedData {
                    decoded = try inflate(decoded, windowBits: -15, limit: limit)
                }
            case "br": decoded = try brotli(decoded, limit: limit)
            default: throw BodyContentError.unsupportedEncoding(encoding)
            }
        }
        guard decoded.count <= limit else { throw BodyContentError.outputLimit }
        return decoded
    }

    public static func text(_ data: Data, contentType: String?, pretty: Bool = false) -> String {
        if pretty, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let string = String(data: formatted, encoding: .utf8) {
            return string
        }
        if let charset = contentType?.split(separator: ";").dropFirst().first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("charset=")
        })?.split(separator: "=", maxSplits: 1).last {
            let value = String(charset).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            let encoding = CFStringConvertIANACharSetNameToEncoding(value as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let string = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return string
            }
        }
        return String(data: data, encoding: .utf8) ?? "Binary data — use Hex or Save Body to inspect these bytes."
    }

    public static func hex(_ data: Data) -> String {
        stride(from: 0, to: data.count, by: 16).map { offset in
            let row = data[offset..<min(offset + 16, data.count)]
            let bytes = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = row.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            return String(format: "%08x  ", offset) + bytes.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }

    private static func inflate(_ data: Data, windowBits: Int32, limit: Int) throws -> Data {
        var output = Data(count: limit + 1)
        var written = 0
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { target in
                proxylab_inflate(input.bindMemory(to: UInt8.self).baseAddress, data.count,
                                target.bindMemory(to: UInt8.self).baseAddress, target.count,
                                &written, windowBits)
            }
        }
        guard result != 1, written <= limit else { throw BodyContentError.outputLimit }
        guard result == 0 else { throw BodyContentError.invalidCompressedData }
        output.count = written
        return output
    }

    private static func brotli(_ data: Data, limit: Int) throws -> Data {
        var output = Data(count: limit + 1)
        let written = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { target in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_BROTLI)
            }
        }
        guard written <= limit else { throw BodyContentError.outputLimit }
        guard written > 0 else { throw BodyContentError.invalidCompressedData }
        output.count = written
        return output
    }
}
