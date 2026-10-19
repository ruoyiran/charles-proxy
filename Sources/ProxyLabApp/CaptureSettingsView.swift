import ProxyLabCore
import SwiftUI

struct CaptureSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = "Include"
    @State private var host = ""
    @State private var path = "/*"
    @State private var method = ""
    @State private var device = ""

    private var current: [CaptureRule] {
        switch section {
        case "Exclude": model.capturePolicy.exclude
        case "Focus": model.focusPolicy.rules
        default: model.capturePolicy.include
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recording Filters & Focus").font(.title2.bold())
            Text("Include limits saved traffic; Exclude wins. Empty Include records all traffic. Focus changes only the visible list. Existing saved requests are retained.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Rules", selection: $section) {
                Text("Include").tag("Include"); Text("Exclude").tag("Exclude"); Text("Focus").tag("Focus")
            }.pickerStyle(.segmented)
            if section == "Focus" {
                Toggle("Show focused requests only", isOn: Binding(get: { model.focusPolicy.enabled }, set: { value in
                    var policy = model.focusPolicy; policy.enabled = value; Task { await model.saveFocusPolicy(policy) }
                }))
            }
            List(current) { rule in
                HStack {
                    Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { value in
                        var rules = current; if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index].enabled = value; save(rules) }
                    })).labelsHidden().toggleStyle(.checkbox)
                    VStack(alignment: .leading) {
                        Text("\(rule.match.host)\(rule.match.path)")
                        Text("\(rule.match.method ?? "All methods") · \(rule.clientAddress ?? "All devices")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { save(current.filter { $0.id != rule.id }) } label: { Image(systemName: "trash") }
                }
            }.frame(height: 220)
            Text("Add rule").font(.headline)
            HStack { TextField("Host or *.example.com", text: $host); TextField("Path glob", text: $path).frame(width: 155) }
            HStack { TextField("Method (optional)", text: $method); TextField("Device IP (optional)", text: $device) }
            HStack {
                Button("Add Rule") {
                    let rule = CaptureRule(match: .init(host: host.trimmingCharacters(in: .whitespaces), path: path,
                                                       method: method.isEmpty ? nil : method.uppercased()),
                                           clientAddress: device.isEmpty ? nil : device.trimmingCharacters(in: .whitespaces))
                    save(current + [rule]); host = ""; method = ""; device = ""
                }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || path.isEmpty)
                Spacer(); Button("Done") { dismiss() }
            }
        }.padding(20).frame(width: 700, height: 510)
    }

    private func save(_ rules: [CaptureRule]) {
        if section == "Focus" { var policy = model.focusPolicy; policy.rules = rules; Task { await model.saveFocusPolicy(policy) } }
        else {
            var policy = model.capturePolicy
            if section == "Include" { policy.include = rules } else { policy.exclude = rules }
            Task { await model.saveCapturePolicy(policy) }
        }
    }
}
