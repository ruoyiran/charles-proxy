# ProxyLab

ProxyLab is a local macOS HTTP debugging proxy. It provides HTTP/1.1 capture, HTTPS inspection for all hosts by default, rewrite rules, request and response breakpoints, and HAR import/export.

## Build and run

Requires macOS 14 or newer, Xcode 16.3 or newer, and network access for Swift Package Manager's first dependency fetch.

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

Select a captured GET or POST and use **Request Headers**, **Request Body**, **Response Headers**, and **Response Body** in the inspector. Body views support decoded text, JSON formatting, raw bytes, and hexadecimal output, with copy and save actions. Decoded display supports gzip, deflate, and Brotli while preserving the captured bytes. A CONNECT entry from an earlier session is an encrypted tunnel; trust the root certificate under **HTTPS Setup** and reload the page to create new decrypted records. Earlier tunnel records cannot be decrypted retrospectively.

Sessions are stored in `~/Library/Application Support/ProxyLab/sessions.sqlite`. Only the first 10 MB of each request or response body is retained; larger traffic still passes through. Imported HAR records are viewable alongside captured requests.

Use **Clear** above the sidebar list to clear the saved session, or right-click a row and choose **Delete Request**. Both actions show a confirmation. New requests continue appearing while recording is enabled. Method badges use distinct colors; status badges show informational responses in teal, success in green, redirects in blue, client errors in orange, and server errors in red.

**Response Body → Preview** selects a viewer from the response Content-Type, with file signatures and URL extensions as fallbacks. It supports a collapsible JSON tree, HTML/SVG, images, PDF, plain text/XML/CSV, and captured audio/video. HTML preview disables JavaScript, navigation, and remote resources. Media plays only from retained local bytes and may be unavailable for incomplete captures or unsupported codecs. Decoded, Raw, and Hex views remain available. Save Body uses the detected file extension for decoded content. Switching requests keeps the selected inspector tab and loads the new request's content.

HTTP/2, gRPC, WebSocket message inspection, QUIC/HTTP/3, remote-device capture, and Charles proprietary session formats are outside this first release.
