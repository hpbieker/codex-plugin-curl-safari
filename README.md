# Curl Safari

Use ordinary `curl` commands on macOS for websites where you are already
logged in through Safari. `curl-safari` automatically supplies matching Safari
cookies without giving Codex or other sandboxed clients Full Disk Access.

Requires macOS and Safari.

## Quick Start

```bash
open -a "$PWD/CurlSafariServer.app"
bin/curl-safari -L https://example.com/account
```

Give `CurlSafariServer.app` Full Disk Access when setting it up for the first
time. `curl-safari` supplies matching Safari cookies; it does not copy bearer
tokens, localStorage, or other browser-only authentication.

## Components

- `CurlSafariServer.app`: privileged Swift server app. This is the only
  process that reads Safari's `Cookies.binarycookies`. It accepts requests on
  `/private/tmp/curl-safari.sock`.
- `bin/curl-safari`: unprivileged Go CLI. It receives a domain-scoped cookie
  jar through the Unix socket and pipes it directly to `curl` without writing
  it to disk.
- `cmd/curl-safari/`: Go source for the CLI.
- `CurlSafariServer/`: Swift source and version-controlled `Info.plist`.
- `CurlSafariServer.xcodeproj`: standard Xcode app project and shared scheme.

## Build

```bash
./build.sh
```

Requires Xcode and Go. Xcode writes the app product directly to the stable
`CurlSafariServer.app` path in the repository root; `build.sh` does not create
the bundle or generate its `Info.plist`.

The Xcode target uses automatic Apple Development signing to keep the app
identity stable across rebuilds. If the signing identity changes, macOS may
require Full Disk Access to be granted again.

## Full Disk Access

Give Full Disk Access to `CurlSafariServer.app` so it can read Safari's cookie
database:

```text
System Settings -> Privacy & Security -> Full Disk Access
```

Use the app bundle, not the inner executable. macOS does not provide an API or
automatic prompt for granting Full Disk Access; the user must enable it in
System Settings.

## Start Server

```bash
open -a "$PWD/CurlSafariServer.app"
```

After rebuilding, restart the server so the running process uses the new
executable:

```bash
pkill -f "$PWD/CurlSafariServer.app/Contents/MacOS/curl-safari-server" || true
open -a "$PWD/CurlSafariServer.app"
```

The server creates `/private/tmp/curl-safari.sock` with mode `0600` and only
accepts clients with the same effective user ID. Requests and responses are
newline-delimited JSON, with one request per connection. The socket path can be
overridden with `CURL_SAFARI_SOCKET_PATH` for isolated testing.

## Curl

```bash
bin/curl-safari -L https://www.finn.no/saved-searches
```

`curl-safari` finds the request URL, asks the local server for a matching
Safari cookie jar, and gives it to `curl` through an anonymous pipe:

```bash
curl -b /dev/fd/3 ...
```

It does not write or print cookie values.

## Safety Shape

- server is the only process that reads Safari cookies
- only the server app needs Full Disk Access; the CLI does not
- Unix socket is mode `0600` and verifies the client UID
- no request or response files are used for client/server communication
- no export-all command
- cookie jars are domain scoped
- cookie jars travel over the private socket and an anonymous pipe
- cookie values are never written to disk by `curl-safari`
- normal CLI output never prints cookie values
