import Foundation

public enum HARCodecError: Error { case invalidFormat }

public enum HARCodec {
    public static func encode(_ transactions: [CapturedTransaction]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries: [[String: Any]] = transactions.map { transaction in
            let request = transaction.request
            let response = transaction.response
            var requestObject: [String: Any] = [
                "method": request.method, "url": request.url, "httpVersion": transaction.requestHTTPVersion ?? "HTTP/1.1",
                "headers": headerObjects(request.headers), "queryString": queryObjects(request.url),
                "cookies": [], "headersSize": -1, "bodySize": request.body.count,
            ]
            if !request.body.isEmpty {
                requestObject["postData"] = contentObject(request.body, mimeType: request.header("Content-Type") ?? "application/octet-stream")
            }
            let responseBody = response?.body ?? Data()
            let responseObject: [String: Any] = [
                "status": response?.status ?? 0, "statusText": HTTPURLResponse.localizedString(forStatusCode: response?.status ?? 0),
                "httpVersion": transaction.responseHTTPVersion ?? "HTTP/1.1", "headers": headerObjects(response?.headers ?? []),
                "cookies": [], "content": contentObject(responseBody, mimeType: response?.header("Content-Type") ?? "application/octet-stream"),
                "redirectURL": response?.header("Location") ?? "", "headersSize": -1, "bodySize": responseBody.count,
            ]
            let elapsed = max(0, (transaction.endedAt ?? transaction.startedAt).timeIntervalSince(transaction.startedAt) * 1_000)
            var entry: [String: Any] = [
                "startedDateTime": formatter.string(from: transaction.startedAt), "time": elapsed,
                "request": requestObject, "response": responseObject, "cache": [:] as [String: String],
                "timings": ["send": 0, "wait": elapsed, "receive": 0],
            ]
            if transaction.requestBodyTruncated || transaction.responseBodyTruncated {
                entry["comment"] = "ProxyLab retained only the first 10 MB of one or more bodies"
            }
            entry["_proxylabRequestBodyTruncated"] = transaction.requestBodyTruncated
            entry["_proxylabResponseBodyTruncated"] = transaction.responseBodyTruncated
            if let address = transaction.clientAddress { entry["_proxylabClientAddress"] = address }
            if let id = transaction.replayOf { entry["_proxylabReplayOf"] = id.uuidString }
            if let trailers = transaction.responseTrailers { entry["_proxylabResponseTrailers"] = headerObjects(trailers) }
            return entry
        }
        return try JSONSerialization.data(withJSONObject: ["log": [
            "version": "1.2", "creator": ["name": "ProxyLab", "version": "1.0"], "entries": entries,
        ]], options: [.prettyPrinted, .sortedKeys])
    }

    public static func decode(_ data: Data) throws -> [CapturedTransaction] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else { throw HARCodecError.invalidFormat }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        return try entries.map { entry in
            guard let request = entry["request"] as? [String: Any],
                  let method = request["method"] as? String,
                  let url = request["url"] as? String,
                  URL(string: url) != nil else { throw HARCodecError.invalidFormat }
            let response = entry["response"] as? [String: Any]
            let startString = entry["startedDateTime"] as? String ?? ""
            let start = formatter.date(from: startString) ?? fallbackFormatter.date(from: startString) ?? Date()
            let elapsed = (entry["time"] as? Double ?? 0) / 1_000
            let requestBody = decodeContent(request["postData"] as? [String: Any])
            let responseBody = decodeContent((response?["content"] as? [String: Any]))
            let parsedRequest = ProxyRequest(method: method, url: url,
                                             headers: decodeHeaders(request["headers"]), body: requestBody)
            let parsedResponse = response.map {
                ProxyResponse(status: $0["status"] as? Int ?? 0,
                              headers: decodeHeaders($0["headers"]), body: responseBody)
            }
            let legacyTruncation = (entry["comment"] as? String) == "ProxyLab retained only the first 10 MB of one or more bodies"
            return CapturedTransaction(startedAt: start, endedAt: start.addingTimeInterval(elapsed),
                                       request: parsedRequest, response: parsedResponse,
                                       requestBodyTruncated: entry["_proxylabRequestBodyTruncated"] as? Bool ?? legacyTruncation,
                                       responseBodyTruncated: entry["_proxylabResponseBodyTruncated"] as? Bool ?? legacyTruncation,
                                       clientAddress: entry["_proxylabClientAddress"] as? String,
                                       requestHTTPVersion: request["httpVersion"] as? String,
                                       responseHTTPVersion: response?["httpVersion"] as? String,
                                       replayOf: (entry["_proxylabReplayOf"] as? String).flatMap(UUID.init(uuidString:)),
                                       responseTrailers: entry["_proxylabResponseTrailers"].map(decodeHeaders))
        }
    }

    private static func headerObjects(_ headers: [HTTPHeader]) -> [[String: String]] {
        headers.map { ["name": $0.name, "value": $0.value] }
    }

    private static func queryObjects(_ url: String) -> [[String: String]] {
        (URLComponents(string: url)?.queryItems ?? []).map { ["name": $0.name, "value": $0.value ?? ""] }
    }

    private static func contentObject(_ body: Data, mimeType: String) -> [String: Any] {
        var object: [String: Any] = ["size": body.count, "mimeType": mimeType]
        if let text = String(data: body, encoding: .utf8) {
            object["text"] = text
        } else {
            object["text"] = body.base64EncodedString()
            object["encoding"] = "base64"
        }
        return object
    }

    private static func decodeHeaders(_ value: Any?) -> [HTTPHeader] {
        (value as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String, let value = $0["value"] as? String else { return nil }
            return HTTPHeader(name: name, value: value)
        }
    }

    private static func decodeContent(_ value: [String: Any]?) -> Data {
        guard let text = value?["text"] as? String else { return Data() }
        if (value?["encoding"] as? String)?.lowercased() == "base64" {
            return Data(base64Encoded: text) ?? Data()
        }
        return Data(text.utf8)
    }
}
