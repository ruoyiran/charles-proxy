import AppKit
import AVKit
import AVFoundation
import PDFKit
import ProxyLabCore
import SwiftUI
import WebKit

struct ResponsePreviewView: View {
    let data: Data
    let preview: BodyPreview
    let contentType: String?
    let truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(preview.kind.rawValue) Preview", systemImage: "doc.richtext")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if preview.kind == .html { Text("Captured content · scripts and network disabled").font(.caption).foregroundStyle(.secondary) }
            }
            Group {
                switch preview.kind {
                case .image: ImageBodyPreview(data: data)
                case .pdf: PDFBodyPreview(data: data)
                case .html: HTMLBodyPreview(data: data, contentType: contentType)
                case .audio, .video:
                    if truncated {
                        ContentUnavailableView("Media capture is incomplete", systemImage: "play.slash",
                                               description: Text("Use Raw or Save Body to inspect the retained bytes."))
                    } else { MediaBodyPreview(data: data, fileExtension: preview.fileExtension) }
                case .json: JSONBodyPreview(data: data)
                case .text: TextBodyPreview(data: data, contentType: contentType)
                case .binary:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No visual preview for this file type. Use Save Body to export the file.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextBodyPreview(data: data, contentType: contentType, hex: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TextBodyPreview: View {
    let data: Data
    let contentType: String?
    var hex = false
    @State private var text = ""

    var body: some View {
        TextEditor(text: .constant(text))
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel(hex ? "Binary hex preview" : "Text preview")
            .task {
                text = await Task.detached {
                    if hex { return BodyContent.hex(Data(data.prefix(64 * 1024))) }
                    return String(BodyContent.text(data, contentType: contentType).prefix(256 * 1024))
                }.value
            }
    }
}

private struct ImageBodyPreview: View {
    let data: Data
    @State private var image: NSImage?
    @State private var actualSize = false

    var body: some View {
        VStack(spacing: 8) {
            if let image {
                HStack {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Actual size", isOn: $actualSize).toggleStyle(.checkbox)
                }
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: actualSize ? image.size.width : geometry.size.width,
                                   height: actualSize ? image.size.height : geometry.size.height)
                            .accessibilityLabel("Response image preview")
                    }
                    .background(Color.secondary.opacity(0.06))
                }
            } else {
                ContentUnavailableView("Image could not be decoded", systemImage: "photo",
                                       description: Text("The body may be incomplete or the image format unsupported."))
            }
        }
        .task { image = NSImage(data: data) }
    }
}

private struct PDFBodyPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        view.setAccessibilityLabel("PDF response preview")
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

/// HTML is loaded only after a network-blocking content rule has been installed.
/// The original page URL is deliberately never used as a base URL.
private struct HTMLBodyPreview: NSViewRepresentable {
    let data: Data
    let contentType: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("HTML response preview")
        let html = BodyContent.text(data, contentType: contentType)
        let policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src data:; base-uri 'none'; form-action 'none'; sandbox"
        let wrapped = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta charset=\"utf-8\">" + html
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ProxyLabCapturedHTML", encodedContentRuleList: rules) { [weak view] list, error in
            guard let view else { return }
            if let list {
                view.configuration.userContentController.add(list)
                view.loadHTMLString(wrapped, baseURL: nil)
            } else {
                view.loadHTMLString("<p>HTML preview is unavailable. Use Decoded to view source.</p>", baseURL: nil)
            }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}

private struct MediaBodyPreview: NSViewRepresentable {
    let data: Data
    let fileExtension: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.setAccessibilityLabel("Media response preview")
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxylab-preview-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            context.coordinator.directory = directory
            let url = directory.appendingPathComponent("body.\(fileExtension)")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let asset = AVURLAsset(url: url, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            view.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        } catch {
            view.setAccessibilityLabel("Media preview unavailable; use Save Body")
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.removeFile()
    }

    final class Coordinator {
        var directory: URL?
        func removeFile() {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = nil
        }
        deinit { removeFile() }
    }
}
