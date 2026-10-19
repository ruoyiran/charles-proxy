# ProxyLab

ProxyLab is a local macOS HTTP debugging proxy. It provides HTTP/1.1 and HTTP/2 capture, HTTPS inspection for all hosts by default, WebSocket messages, request replay, capture filters, rewrite rules, request and response breakpoints, and HAR import/export.

## Build and run

Requires macOS 14 or newer, Swift 6.2 or newer, and network access for Swift Package Manager's first dependency fetch.

```sh
swift test -j 8
./Scripts/package-local.sh release
open dist/ProxyLab.app
```

The packaging script creates a locally signed universal (Apple Silicon and Intel) `dist/ProxyLab.app` and `dist/ProxyLab.dmg`. This local build is not notarized for public distribution.

## Capture traffic

The proxy listens on `127.0.0.1:8888` by default. Click **Enable System Proxy** to route this Mac's HTTP and HTTPS traffic through it, or configure a browser manually. ProxyLab saves the prior system proxy settings and restores them on normal exit. If the app exits unexpectedly, use the **Restore** banner on the next launch.

For HTTPS inspection, open **HTTPS Setup**, export the public certificate, and explicitly trust it for SSL in Keychain Access. ProxyLab automatically inspects all HTTPS traffic routed through it; no hostname list is required. The root private key stays in the local Keychain. Certificate-pinned clients may reject interception. Legacy `ssl-hosts.txt` settings are ignored.

If a site fails because the local DNS server returns an unusable address, add its exact hostname under **Proxy Settings → Trusted DNS routing**. ProxyLab will resolve only those names through `https://dns.google/resolve` and connect to the returned public address while retaining the requested hostname for TLS and certificate validation. For example, add `www.google.com.hk` there when the local resolver returns a private address that resets TLS. This setting sends the listed hostnames to Google's DNS service; leave it empty to use system DNS for all traffic.

macOS may request Keychain access the first time a locally signed build uses the CA, or after the app is rebuilt with a new ad-hoc signature. Grant access only when you are intentionally enabling HTTPS inspection.

## Connect a phone

Open **Mobile Setup** in the toolbar and turn on **Allow mobile connections**. ProxyLab switches from loopback to an IPv4 LAN listener on the same port; this option is off each time the app launches. Connect your iPhone or Android phone to the same Wi-Fi as the Mac. Select the Mac address for that network, scan the setup QR code, then click **Allow** for the phone's IP address in ProxyLab and reload the phone's page.

Configure the phone's Wi-Fi HTTP proxy manually using the displayed server IP and port, with no username or password. On iOS, use Safari to open the setup page and download the CA, install the downloaded profile, then enable full trust under **Settings → General → About → Certificate Trust Settings**. On Android, install the downloaded `.cer` as a CA certificate under Security / Credentials. Android 7+ apps you control need user certificate trust in their debug Network Security Configuration; certificate-pinned apps can still refuse inspection.

The setup page and certificate download are served by ProxyLab locally. Only the public DER certificate is downloadable; the private key stays in this Mac's Keychain. Requests display the source IP, and the sidebar's **Device** picker filters saved records. IP approvals apply to the current mobile capture session. **Revoke** closes that device's existing connections; turning mobile access off closes all remote clients and clears approvals. IP addresses identify connections, not hardware identities; re-approve if the phone changes Wi-Fi addresses.

If the phone cannot connect, check macOS local network permission, the firewall, and Wi-Fi client isolation. This feature captures HTTP/HTTPS connections that honor the configured Wi-Fi proxy, not cellular traffic, QUIC, or apps that bypass the proxy. Disable the phone's Wi-Fi proxy and remove unneeded certificate trust after testing.

Select a captured GET or POST and use **Request Headers**, **Request Body**, **Response Headers**, and **Response Body** in the inspector. Body views support decoded text, JSON formatting, raw bytes, and hexadecimal output, with copy and save actions. Decoded display supports gzip, deflate, and Brotli while preserving the captured bytes. A CONNECT entry from an earlier session is an encrypted tunnel; trust the root certificate under **HTTPS Setup** and reload the page to create new decrypted records. Earlier tunnel records cannot be decrypted retrospectively.

Sessions are stored in `~/Library/Application Support/ProxyLab/sessions.sqlite`. Only the first 10 MB of each request or response body is retained; larger traffic still passes through. Imported HAR records are viewable alongside captured requests. HAR round trips preserve separate body truncation flags so incomplete uploads cannot be replayed as complete requests. Older ProxyLab HAR files with a generic truncation comment are treated conservatively as incomplete in both directions.

Use **Clear** above the sidebar list to clear the saved session, or right-click a row and choose **Delete Request**. Both actions show a confirmation. New requests continue appearing while recording is enabled. Method badges use distinct colors; status badges show informational responses in teal, success in green, redirects in blue, client errors in orange, and server errors in red.

**Response Body → Preview** selects a viewer from the response Content-Type, with file signatures and URL extensions as fallbacks. It supports a collapsible JSON tree, HTML/SVG, images, PDF, plain text/XML/CSV, and captured audio/video. HTML preview disables JavaScript, navigation, and remote resources. Media plays only from retained local bytes and may be unavailable for incomplete captures or unsupported codecs. Decoded, Raw, and Hex views remain available. Save Body uses the detected file extension for decoded content. Switching requests keeps the selected inspector tab and loads the new request's content.

## Replay and edit requests

Right-click a recorded request and choose **Repeat Request** to send it again, or **Edit and Send…** to edit its method, URL, headers and body. **Compose** creates a new request. A sent request appears as a new record linked to its original; automatic recording pause and capture filters do not hide explicitly sent results. Host and Content-Length are regenerated, hop-by-hop and proxy authorization headers are removed. Binary bodies can be retained or replaced with a file (up to 10 MB). Truncated captured bodies must be replaced before sending. CONNECT and WebSocket upgrades are not ordinary replay requests. **Stop** cancels an in-progress send. Replaying may repeat the original server-side action.

## Recording filters and Focus

Open **Recording Filters** to add Include, Exclude or Focus rules by host, path glob, method and optional device IP. Empty active Include rules allow all traffic; Exclude takes precedence. Recording filters decide which future requests are saved and never prevent forwarding. **Focus** filters only the displayed saved records; **Show All** restores the full view. Right-click a request to focus its host or exclude that host from future recording. Rules persist across app launches.

## WebSocket and HTTP/2

WS and WSS upgrades over HTTP/1.1 retain handshake headers and stream messages to the **WebSocket** inspector tab. Messages show direction, time, opcode and captured payload with decoded/hex viewing. Text fragments are assembled, client frames are remasked, and ping/pong/close frames remain visible. Captures retain up to 1 MB per message; the live view loads the latest 200 messages within a 2 MB payload budget and previews at most 256 KB per message. Wire frames are limited to 4 MB and queued traffic is bounded. The proxy declines permessage-deflate negotiation and forwards uncompressed messages. Recording exclusions leave the WebSocket connection working but do not save its handshake or messages.

Intercepted TLS negotiates HTTP/2 or HTTP/1.1 through ALPN; the upstream connection also automatically negotiates HTTP/2 with HTTP/1.1 fallback. Concurrent streams share the TLS connection. Each request displays downstream and upstream protocol versions separately, including mixed-protocol connections. Response trailers are forwarded and appear in **Response Headers**. HAR exports retain protocol versions and response trailers; WebSocket messages remain in the local session database and are not included in HAR. HTTP/2 extended CONNECT WebSockets (RFC 8441), h2c, gRPC-specific message decoding, QUIC/HTTP/3 and Charles proprietary session formats are outside this release.
