# Curl Safari

Use Safari cookies with `curl` without giving Codex or other sandboxed clients
Full Disk Access.

## Components

- `CurlSafariServer.app`: privileged Swift server app. This is the only
  process that reads Safari's `Cookies.binarycookies`. It accepts requests on
  `/private/tmp/curl-safari.sock`.
- `bin/curl-safari`: unprivileged Go CLI. It calls `curl` with a temporary
  domain-scoped cookie jar obtained through the Unix socket.
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

The Xcode target uses ad-hoc signing by default, matching the currently built
`OutlookLocalServer.app` on this machine. This needs no development team, but
macOS may require Full Disk Access to be granted again after a rebuild. A valid
`Apple Development` identity can be configured in Xcode later to retain a
certificate-backed identity across rebuilds.

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

The app probes read access during launch and logs whether Full Disk Access is
available before the server begins accepting clients.

The server creates `/private/tmp/curl-safari.sock` with mode `0600` and only
accepts clients with the same effective user ID. Requests and responses are
newline-delimited JSON, with one request per connection. The socket path can be
overridden with `CURL_SAFARI_SOCKET_PATH` for isolated testing.

## Curl

```bash
bin/curl-safari -L https://www.finn.no/saved-searches
```

`curl-safari` finds the request URL, asks the local server for a matching
Safari cookie jar, then runs:

```bash
curl -b <temporary-cookie-jar> ...
```

It does not print cookie values.

## Safety Shape

- server is the only process that reads Safari cookies
- only the server app needs Full Disk Access; the CLI does not
- Unix socket is mode `0600` and verifies the client UID
- no request or response files are used for client/server communication
- no export-all command
- cookie jars are domain scoped
- cookie jars are written with `0600`
- default jar TTL is 600 seconds
- normal CLI output never prints cookie values
