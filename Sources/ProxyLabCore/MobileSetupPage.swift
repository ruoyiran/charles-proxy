import Foundation

public struct MobileSetupResponse: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public var downloadName: String? = nil
}

public enum MobileSetupPage {
    public static let hostname = "proxylab.local"
    public static let setupPath = "/setup"
    public static let certificatePath = "/root-ca.cer"

    public static func response(for url: String, method: String, port: Int, certificateDER: Data,
                                localAddresses: [String]) -> MobileSetupResponse? {
        guard let target = URL(string: url), target.scheme == "http", let host = target.host else { return nil }
        let direct = (localAddresses.contains(host) || MobileAccess.isLoopback(host)) && target.port == port
        guard host == hostname || direct else { return nil }
        guard method == "GET" || method == "HEAD" else {
            return .init(status: 405, contentType: "text/plain; charset=utf-8", body: Data("Use GET to open Mobile Setup.".utf8))
        }
        if target.path == certificatePath {
            return .init(status: 200, contentType: "application/x-x509-ca-cert", body: certificateDER,
                         downloadName: "ProxyLab-Root-CA.cer")
        }
        guard target.path == setupPath || target.path == "/" else {
            return .init(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8))
        }
        let address = direct ? host : localAddresses.first ?? "Mac LAN IP"
        let html = """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ProxyLab 手机接入</title><style>body{font:16px -apple-system,sans-serif;max-width:680px;margin:32px auto;padding:0 20px;line-height:1.7;color:#253047}h1{font-size:26px}section{background:#f4f6fa;padding:20px;border-radius:14px;margin:18px 0}a.button{display:block;background:#5261ec;color:white;text-decoration:none;text-align:center;border-radius:10px;padding:12px}code{background:#e5e9f1;padding:3px 5px;border-radius:4px}</style>
        <h1>ProxyLab 手机接入</h1><p>手机与 Mac 连接同一 Wi-Fi，并在 ProxyLab 中允许此设备。</p>
        <section><h2>1. 设置 Wi-Fi HTTP 代理</h2><p>服务器：<code>\(address)</code><br>端口：<code>\(port)</code><br>无需用户名和密码。</p>
        <p>iOS：设置 → Wi-Fi → 当前网络 ⓘ → 配置代理 → 手动。<br>Android：当前 Wi-Fi 网络 → 修改/高级选项 → 代理 → 手动。</p></section>
        <section><h2>2. 安装 ProxyLab 根证书</h2><a class="button" href="/root-ca.cer">下载根证书 (.cer)</a>
        <h3>iOS</h3><p>使用 Safari 打开本页。下载后在设置 → 已下载描述文件中安装。然后进入设置 → 通用 → 关于本机 → 证书信任设置，为 ProxyLab Local Root CA 开启完全信任。</p>
        <h3>Android</h3><p>下载后进入设置 → 安全/加密与凭据 → 安装证书 → CA 证书。不同厂商菜单名称可能不同。</p>
        <p>Android 7 及以上的 App 默认不信任用户 CA。你控制的 App 可在 debug 的 Network Security Configuration 中添加用户证书信任；证书固定的 App 可能仍会拒绝连接。</p></section>
        <section><h2>3. 验证抓包</h2><p>刷新手机中的网页或 App，请求应显示在 Mac 上的 ProxyLab，并带有设备 IP。手机开启代理只影响遵循此设置的 HTTP/HTTPS 流量，不包含绕过代理的连接。</p>
        <p>连接失败时检查同一 Wi-Fi、Mac 防火墙、本地网络权限及 Wi-Fi 客户端隔离。测试完成后关闭手机 Wi-Fi 代理，并移除不再使用的证书信任。</p></section></html>
        """
        return .init(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }
}
