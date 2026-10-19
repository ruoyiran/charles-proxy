# ProxyLab

ProxyLab is a local macOS HTTP debugging proxy. It provides HTTP/1.1 capture, selected-host HTTPS inspection, rewrite rules, request and response breakpoints, and HAR import/export.

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

For HTTPS inspection, open **Root Certificate…**, export the public certificate, and explicitly trust it for SSL in Keychain Access. Add the desired hostnames under **Proxy Settings**. The root private key stays in the local Keychain. Unlisted HTTPS hosts pass through without decryption. Certificate-pinned clients may reject interception.

macOS may request Keychain access the first time a locally signed build uses the CA, or after the app is rebuilt with a new ad-hoc signature. Grant access only when you are intentionally enabling HTTPS inspection.

Sessions are stored in `~/Library/Application Support/ProxyLab/sessions.sqlite`. Only the first 10 MB of each request or response body is retained; larger traffic still passes through. Imported HAR records are viewable alongside captured requests.

HTTP/2, gRPC, WebSocket message inspection, QUIC/HTTP/3, remote-device capture, and Charles proprietary session formats are outside this first release.
