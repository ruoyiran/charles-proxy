import Foundation
import SwiftUI
import ProxyLabCore

private struct JSONNode: Identifiable, Sendable {
    let id: String
    let name: String
    let value: String
    let children: [JSONNode]?
}

struct JSONBodyPreview: View {
    let data: Data
    @State private var nodes: [JSONNode] = []
    @State private var invalid = false
    @State private var limited = false
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading { ProgressView("Reading JSON…") }
            else if invalid {
                ContentUnavailableView("JSON could not be parsed", systemImage: "curlybraces",
                                       description: Text("Use Decoded to view the response as text."))
            } else {
                List {
                    OutlineGroup(nodes, children: \.children) { node in
                        HStack(alignment: .top, spacing: 12) {
                            Text(node.name).font(.system(.body, design: .monospaced).bold())
                                .foregroundStyle(.blue).textSelection(.enabled)
                            Text(node.value).font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                        }
                    }
                }
                .accessibilityLabel("JSON response tree")
                if limited { Text("Tree limited to 2,000 values and 32 levels. Decoded and Save Body retain the complete captured content.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task {
            let result = await Task.detached { () -> ([JSONNode], Bool, Bool) in
                guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return ([], true, false) }
                var remaining = 2000
                var limited = false
                func node(_ value: Any, name: String, path: String, depth: Int) -> JSONNode {
                    remaining -= 1
                    if remaining <= 0 || depth >= 32 {
                        limited = true
                        return JSONNode(id: path, name: name, value: "…", children: nil)
                    }
                    if let dictionary = value as? [String: Any] {
                        let keys = dictionary.keys.sorted()
                        var children: [JSONNode] = []
                        for key in keys {
                            guard remaining > 0 else { limited = true; break }
                            let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                            children.append(node(dictionary[key]!, name: key, path: path + "/" + escaped, depth: depth + 1))
                        }
                        if children.count < keys.count { limited = true }
                        return JSONNode(id: path, name: name, value: "{\(keys.count) keys}", children: children.isEmpty ? nil : children)
                    }
                    if let array = value as? [Any] {
                        var children: [JSONNode] = []
                        for (index, value) in array.enumerated() {
                            guard remaining > 0 else { limited = true; break }
                            children.append(node(value, name: "[\(index)]", path: path + "/\(index)", depth: depth + 1))
                        }
                        if children.count < array.count { limited = true }
                        return JSONNode(id: path, name: name, value: "[\(array.count) items]", children: children.isEmpty ? nil : children)
                    }
                    let text: String
                    if let string = value as? String { text = "\"" + String(string.prefix(4096)) + "\"" }
                    else if value is NSNull { text = "null" }
                    else if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                            let rendered = String(data: bytes, encoding: .utf8) { text = rendered }
                    else { text = String(describing: value) }
                    return JSONNode(id: path, name: name, value: text, children: nil)
                }
                // Display root members immediately so common API objects need no initial click.
                let root = node(object, name: "root", path: "$", depth: 0)
                return (root.children ?? [root], false, limited)
            }.value
            guard !Task.isCancelled else { return }
            nodes = result.0; invalid = result.1; limited = result.2; loading = false
        }
    }
}
