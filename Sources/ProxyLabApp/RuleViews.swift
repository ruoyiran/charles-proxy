import SwiftUI
import ProxyLabCore

struct RewriteRulesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = "*"
    @State private var path = "/*"
    @State private var method = ""
    @State private var phase = RulePhase.request
    @State private var action = "Set header"
    @State private var headerName = ""
    @State private var value = ""
    @State private var find = ""

    private let actions = ["Set header", "Remove header", "Replace text", "Replace URL"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rewrite Rules").font(.title2).bold()
            Text("Rules run in list order before a request or response breakpoint.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.rewriteRules) { rule in
                    HStack {
                        Button {
                            var rules = model.rewriteRules
                            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                                rules[index].enabled.toggle()
                                Task { await model.saveRewriteRules(rules) }
                            }
                        } label: { Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle") }
                            .buttonStyle(.plain)
                        VStack(alignment: .leading) {
                            Text(rule.name).bold()
                            Text("\(rule.phase.rawValue) · \(rule.match.host)\(rule.match.path)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.saveRewriteRules(model.rewriteRules.filter { $0.id != rule.id }) }
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
            .frame(height: 170)
            Divider()
            Text("Add rule").font(.headline)
            HStack {
                TextField("Name", text: $name)
                Picker("Phase", selection: $phase) {
                    Text("Request").tag(RulePhase.request)
                    Text("Response").tag(RulePhase.response)
                }.frame(width: 180)
            }
            HStack {
                TextField("Host (example.com or *.example.com)", text: $host)
                TextField("Path glob", text: $path).frame(width: 140)
                TextField("Method (optional)", text: $method).frame(width: 120)
            }
            HStack {
                Picker("Action", selection: $action) {
                    ForEach(actions, id: \.self) { Text($0).tag($0) }
                }.frame(width: 190)
                if action == "Set header" || action == "Remove header" {
                    TextField("Header name", text: $headerName)
                }
                if action == "Replace text" { TextField("Find text", text: $find) }
                if action != "Remove header" { TextField(action == "Replace text" ? "Replacement" : "Value", text: $value) }
            }
            HStack {
                Button("Add Rule") { addRule() }
                    .disabled(name.isEmpty || host.isEmpty || (action == "Replace text" && find.isEmpty))
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(18)
    }

    private func addRule() {
        let operation: RuleAction
        switch action {
        case "Remove header": operation = .removeHeader(name: headerName)
        case "Replace text": operation = .replaceText(find: find, replace: value)
        case "Replace URL": operation = .replaceURL(value)
        default: operation = .setHeader(name: headerName, value: value)
        }
        let rule = RewriteRule(name: name, match: RuleMatch(host: host, path: path,
                                                            method: method.isEmpty ? nil : method),
                               phase: phase, action: operation)
        Task { await model.saveRewriteRules(model.rewriteRules + [rule]) }
        name = ""
        headerName = ""
        value = ""
        find = ""
    }
}

struct BreakpointRulesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = "*"
    @State private var path = "/*"
    @State private var method = ""
    @State private var phase = RulePhase.request

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Breakpoints").font(.title2).bold()
            Text("Matching traffic waits for Execute, Cancel, or Abort. A 120-second timeout cancels the pause.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.breakpointRules) { rule in
                    HStack {
                        Button {
                            var rules = model.breakpointRules
                            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                                rules[index].enabled.toggle()
                                Task { await model.saveBreakpointRules(rules) }
                            }
                        } label: { Image(systemName: rule.enabled ? "pause.circle.fill" : "circle") }
                            .buttonStyle(.plain)
                        Text("\(rule.phase.rawValue) · \(rule.match.host)\(rule.match.path)")
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.saveBreakpointRules(model.breakpointRules.filter { $0.id != rule.id }) }
                        } label: { Image(systemName: "trash") }
                    }
                }
            }.frame(height: 200)
            HStack {
                TextField("Host", text: $host)
                TextField("Path glob", text: $path)
                TextField("Method (optional)", text: $method)
                Picker("Phase", selection: $phase) {
                    Text("Request").tag(RulePhase.request)
                    Text("Response").tag(RulePhase.response)
                }.frame(width: 170)
            }
            HStack {
                Button("Add Breakpoint") {
                    let rule = BreakpointRule(match: RuleMatch(host: host, path: path,
                                                               method: method.isEmpty ? nil : method), phase: phase)
                    Task { await model.saveBreakpointRules(model.breakpointRules + [rule]) }
                }
                .disabled(host.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(18)
    }
}
