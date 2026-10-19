import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import ProxyLabCore

struct MobileSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAddress = ""

    private var address: String { selectedAddress.isEmpty ? model.lanAddresses.first?.address ?? "" : selectedAddress }
    private var setupURL: String { "http://\(address):\(model.proxyPort)/setup" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Mobile Setup", systemImage: "iphone").font(.title2.bold())
                Spacer()
                if model.mobileSetupInProgress { ProgressView().controlSize(.small) }
                Toggle("Allow mobile connections", isOn: Binding(
                    get: { model.mobileConnectionsEnabled },
                    set: { enabled in Task { await model.setMobileConnectionsEnabled(enabled) } }
                )).toggleStyle(.switch).disabled(model.mobileSetupInProgress || model.proxyUnavailable)
            }
            Text("Connect your phone and Mac to the same Wi-Fi. New devices require approval below before they can use the proxy or download its public certificate.")
                .font(.callout).foregroundStyle(.secondary)
            if model.mobileConnectionsEnabled {
                HStack(alignment: .top, spacing: 22) {
                    QRCodeView(value: setupURL).frame(width: 155, height: 155)
                        .accessibilityLabel("Mobile certificate setup QR code")
                    VStack(alignment: .leading, spacing: 10) {
                        if model.lanAddresses.isEmpty {
                            Text("No LAN IPv4 address found. Connect this Mac to Wi-Fi or Ethernet.").foregroundStyle(.orange)
                        } else {
                            Picker("Mac address", selection: $selectedAddress) {
                                Text("Automatic").tag("")
                                ForEach(model.lanAddresses) { item in Text("\(item.address) (\(item.interface))").tag(item.address) }
                            }
                            Text("Proxy server: \(address)").textSelection(.enabled).font(.headline)
                            Text("Port: \(model.proxyPort) · no username or password").textSelection(.enabled)
                            Text(setupURL).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy Setup URL") { copy(setupURL) }
                        }
                    }
                }
                Text("Scan the QR code, then allow the phone in ProxyLab and reload its page. Configure the Wi-Fi HTTP proxy using the server and port above.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Mobile connections are off. ProxyLab listens only on this Mac.")
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            Text("Devices").font(.headline)
            if model.mobileDevices.isEmpty {
                Text("No phone has connected yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.mobileDevices) { device in
                            HStack {
                                Image(systemName: "iphone")
                                VStack(alignment: .leading) {
                                    Text(device.address).font(.body.monospaced()).textSelection(.enabled)
                                    Text(device.access == .pending ? "Waiting for approval · reload after allowing" : device.access.rawValue.capitalized)
                                        .font(.caption).foregroundStyle(device.access == .allowed ? .green : .secondary)
                                }
                                Spacer()
                                if device.access != .allowed {
                                    Button("Allow") { Task { await model.setDeviceAccess(.allowed, address: device.address) } }
                                }
                                if device.access != .denied {
                                    Button(device.access == .allowed ? "Revoke" : "Deny") { Task { await model.setDeviceAccess(.denied, address: device.address) } }
                                }
                            }
                            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 150)
            }
            Divider()
            Text("iOS: open the setup page in Safari, install the downloaded profile, then enable full trust under Settings → General → About → Certificate Trust Settings.")
                .font(.caption)
            Text("Android: install the downloaded CA certificate under Security / Credentials. Android 7+ apps you control must trust user certificates in their debug Network Security Configuration. Certificate-pinned apps may reject inspection.")
                .font(.caption)
            Text("Approvals last for this mobile capture session. Turning mobile connections off closes device connections and revokes approvals. If a phone cannot connect, check Mac local-network permission, firewall and Wi-Fi client isolation.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct QRCodeView: View {
    let value: String
    private var image: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }

    var body: some View {
        if let image {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
