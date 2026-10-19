import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1

final class ProxyHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let engine: ProxyEngine
    private let tunnelAuthority: ProxyAuthority?
    private let tlsIntercepted: Bool
    private var currentHead: HTTPRequestHead?
    private var currentBody = Data()
    private var currentBodyFile: URL?
    private var currentBodyHandle: FileHandle?
    private var currentBodyLength = 0
    private static let captureLimit = 10 * 1_024 * 1_024

    init(engine: ProxyEngine, tunnelAuthority: ProxyAuthority? = nil, tlsIntercepted: Bool = false) {
        self.engine = engine
        self.tunnelAuthority = tunnelAuthority
        self.tlsIntercepted = tlsIntercepted
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            currentHead = head
            currentBody.removeAll(keepingCapacity: true)
            currentBodyFile = nil
            currentBodyHandle = nil
            currentBodyLength = 0
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                do {
                    currentBodyLength += bytes.count
                    if currentBodyHandle == nil && currentBodyLength > Self.captureLimit {
                        let path = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("proxylab-upload-\(UUID().uuidString)")
                        guard FileManager.default.createFile(atPath: path.path, contents: nil,
                                                             attributes: [.posixPermissions: 0o600]) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        let handle = try FileHandle(forWritingTo: path)
                        try handle.write(contentsOf: currentBody)
                        currentBodyFile = path
                        currentBodyHandle = handle
                    }
                    try currentBodyHandle?.write(contentsOf: Data(bytes))
                    if currentBody.count < Self.captureLimit {
                        currentBody.append(contentsOf: bytes.prefix(Self.captureLimit - currentBody.count))
                    }
                } catch {
                    context.close(promise: nil)
                }
            }
        case .end:
            guard let head = currentHead else { return }
            let body = currentBody
            let bodyFile = currentBodyFile
            let bodyLength = currentBodyLength
            try? currentBodyHandle?.close()
            currentHead = nil
            currentBody = Data()
            currentBodyFile = nil
            currentBodyHandle = nil
            currentBodyLength = 0
            let headers = head.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
            let url = Self.absoluteURL(head, tunnelAuthority: tunnelAuthority)
            let request = ProxyRequest(method: head.method.rawValue, url: url, headers: headers, body: body)
            let channel = context.channel
            Task { await handle(request, on: channel, bodyFile: bodyFile, bodyLength: bodyLength) }
        }
    }

    private func handle(_ original: ProxyRequest, on channel: Channel, bodyFile: URL?, bodyLength: Int) async {
        defer { if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) } }
        let requestTruncated = bodyFile != nil
        var request = await engine.prepare(original, allowBodyChanges: !requestTruncated)
        var transaction = CapturedTransaction(request: request, tlsIntercepted: tlsIntercepted,
                                              requestBodyTruncated: requestTruncated)
        var didWriteResponseHead = false
        var completedResponse = false
        do {
            let requestDecision: BreakpointDecision = requestTruncated ? .cancel :
                await engine.breakpointCenter.intercept(request: request, response: nil, phase: .request)
            switch requestDecision {
            case .execute(let edited, _): if let edited { request = edited }
            case .cancel: break
            case .abort: throw ProxyInterceptionError.aborted
            }
            transaction.request = request
            let response = try await engine.execute(request, bodyFile: bodyFile, bodyLength: bodyLength)
            let status = Int(response.status.code)
            let upstreamHeaders = response.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
                .filter { !ProxyEngine.isHopByHop($0.name) }
            let needsBuffer = await engine.responseNeedsBuffer(for: request)
            let hasResponseBreakpoint = await engine.breakpointCenter.shouldIntercept(request: request, phase: .response)
            var streaming = !needsBuffer
            var buffer = Data()
            var capture = Data()
            var bytesReceived = 0
            var outgoingHeaders = [HTTPHeader]()
            var largeBodyURL: URL?
            var largeBodyHandle: FileHandle?
            defer {
                try? largeBodyHandle?.close()
                if let largeBodyURL { try? FileManager.default.removeItem(at: largeBodyURL) }
            }
            if streaming && !hasResponseBreakpoint {
                var headOnly = ProxyResponse(status: status, headers: upstreamHeaders)
                await engine.rewriteResponse(&headOnly, for: request, allowBodyChanges: false)
                outgoingHeaders = try await sendHead(status: headOnly.status, headers: headOnly.headers,
                                                     bodyLength: nil, requestMethod: request.method, on: channel)
                didWriteResponseHead = true
            }
            for try await chunk in response.body {
                bytesReceived += chunk.readableBytes
                if !streaming && buffer.count + chunk.readableBytes <= Self.captureLimit {
                    var copy = chunk
                    if let bytes = copy.readBytes(length: copy.readableBytes) { buffer.append(contentsOf: bytes) }
                    continue
                }
                if !streaming {
                    streaming = true
                    var headOnly = ProxyResponse(status: status, headers: upstreamHeaders)
                    await engine.rewriteResponse(&headOnly, for: request, allowBodyChanges: false)
                    if !hasResponseBreakpoint {
                        outgoingHeaders = try await sendHead(status: headOnly.status, headers: headOnly.headers,
                                                             bodyLength: nil, requestMethod: request.method, on: channel)
                        didWriteResponseHead = true
                    } else {
                        let path = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("proxylab-response-\(UUID().uuidString)")
                        guard FileManager.default.createFile(atPath: path.path, contents: nil,
                                                             attributes: [.posixPermissions: 0o600]) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        largeBodyURL = path
                        largeBodyHandle = try FileHandle(forWritingTo: path)
                        try largeBodyHandle?.write(contentsOf: buffer)
                    }
                    capture = buffer
                    if !buffer.isEmpty && !hasResponseBreakpoint {
                        try await sendBody(ByteBuffer(bytes: buffer), on: channel)
                    }
                    buffer.removeAll(keepingCapacity: false)
                }
                if capture.count < Self.captureLimit {
                    var copy = chunk
                    if let bytes = copy.readBytes(length: min(copy.readableBytes, Self.captureLimit - capture.count)) {
                        capture.append(contentsOf: bytes)
                    }
                }
                if hasResponseBreakpoint {
                    var copy = chunk
                    if let bytes = copy.readBytes(length: copy.readableBytes) {
                        try largeBodyHandle?.write(contentsOf: Data(bytes))
                    }
                } else {
                    try await sendBody(chunk, on: channel)
                }
            }
            if streaming && !hasResponseBreakpoint {
                try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
                completedResponse = true
                transaction.response = ProxyResponse(status: status, headers: outgoingHeaders, body: capture)
                transaction.responseBodyTruncated = bytesReceived > capture.count
            } else if streaming {
                try largeBodyHandle?.close()
                largeBodyHandle = nil
                var preview = ProxyResponse(status: status, headers: upstreamHeaders, body: capture)
                let decision = await engine.breakpointCenter.intercept(request: request, response: preview,
                                                                      phase: .response, bodyTruncated: true)
                switch decision {
                case .abort:
                    throw ProxyInterceptionError.aborted
                case .execute(_, let edited):
                    if let edited {
                        preview.status = edited.status
                        preview.headers = edited.headers
                    }
                case .cancel: break
                }
                var headOnly = ProxyResponse(status: preview.status, headers: preview.headers)
                await engine.rewriteResponse(&headOnly, for: request, allowBodyChanges: false)
                outgoingHeaders = try await sendHead(status: headOnly.status, headers: headOnly.headers,
                                                     bodyLength: bytesReceived, requestMethod: request.method, on: channel)
                didWriteResponseHead = true
                if let largeBodyURL {
                    let reader = try FileHandle(forReadingFrom: largeBodyURL)
                    defer { try? reader.close() }
                    while true {
                        let data = try reader.read(upToCount: 64 * 1_024) ?? Data()
                        if data.isEmpty { break }
                        try await sendBody(ByteBuffer(bytes: data), on: channel)
                    }
                }
                try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
                completedResponse = true
                preview.body = capture
                transaction.response = preview
                transaction.responseBodyTruncated = bytesReceived > capture.count
            } else {
                var editable = ProxyResponse(status: status, headers: upstreamHeaders, body: buffer)
                await engine.rewriteResponse(&editable, for: request)
                let responseDecision = await engine.breakpointCenter.intercept(request: request,
                                                                              response: editable, phase: .response)
                switch responseDecision {
                case .execute(_, let edited): if let edited { editable = edited }
                case .cancel: break
                case .abort: throw ProxyInterceptionError.aborted
                }
                outgoingHeaders = try await sendHead(status: editable.status, headers: editable.headers,
                                                     bodyLength: editable.body.count, requestMethod: request.method,
                                                     on: channel)
                didWriteResponseHead = true
                if !editable.body.isEmpty { try await sendBody(ByteBuffer(bytes: editable.body), on: channel) }
                try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
                completedResponse = true
                transaction.response = ProxyResponse(status: editable.status, headers: outgoingHeaders,
                                                     body: editable.body.prefix(Self.captureLimit))
                transaction.responseBodyTruncated = editable.body.count > Self.captureLimit
            }
        } catch {
            transaction.error = String(describing: error)
            if completedResponse {
                // A complete response has already been sent; retain only the session error.
            } else if didWriteResponseHead {
                try? await channel.close().get()
            } else {
                let body = Data("ProxyLab upstream error: \(error)".utf8)
                let headers = [HTTPHeader(name: "Content-Type", value: "text/plain; charset=utf-8")]
                _ = try? await sendHead(status: 502, headers: headers, bodyLength: body.count,
                                       requestMethod: request.method, on: channel)
                try? await sendBody(ByteBuffer(bytes: body), on: channel)
                try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
            }
        }
        transaction.endedAt = Date()
        await engine.save(transaction)
    }

    private func sendHead(status: Int, headers: [HTTPHeader], bodyLength: Int?, requestMethod: String,
                          on channel: Channel) async throws -> [HTTPHeader] {
        var result = headers.filter { !ProxyEngine.isHopByHop($0.name) }
        let bodyAllowed = requestMethod.uppercased() != "HEAD" && status != 204 && status != 304 && status >= 200
        if let bodyLength {
            result.removeAll { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            result.append(HTTPHeader(name: "Content-Length", value: String(bodyLength)))
        } else if bodyAllowed && !result.contains(where: { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }) {
            result.append(HTTPHeader(name: "Transfer-Encoding", value: "chunked"))
        }
        var nioHeaders = HTTPHeaders()
        for header in result { nioHeaders.add(name: header.name, value: header.value) }
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: nioHeaders)
        try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
        return result
    }

    private func sendBody(_ bytes: ByteBuffer, on channel: Channel) async throws {
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bytes))).get()
    }

    private static func absoluteURL(_ head: HTTPRequestHead, tunnelAuthority: ProxyAuthority?) -> String {
        if head.uri.hasPrefix("http://") || head.uri.hasPrefix("https://") { return head.uri }
        if let tunnelAuthority {
            let host = tunnelAuthority.host.contains(":") ? "[\(tunnelAuthority.host)]" : tunnelAuthority.host
            return "https://\(host):\(tunnelAuthority.port)\(head.uri.hasPrefix("/") ? "" : "/")\(head.uri)"
        }
        let host = head.headers.first(name: "Host") ?? ""
        return "http://\(host)\(head.uri.hasPrefix("/") ? "" : "/")\(head.uri)"
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private enum ProxyInterceptionError: Error { case aborted }
