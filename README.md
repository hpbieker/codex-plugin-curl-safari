# Curl Safari

Use ordinary `curl` commands on macOS for websites where you are already
logged in through Safari. `curl-safari` automatically supplies matching Safari
cookies without giving Codex or other sandboxed clients Full Disk Access.

## Requirements

- macOS 14 or later
- Safari
- Xcode and Go for building from source

## Build and Setup

Build the helper app and CLI:

```bash
./build.sh
```

Give `CurlSafariServer.app` Full Disk Access:

```text
System Settings -> Privacy & Security -> Full Disk Access
```

Add the app bundle, not its inner executable. macOS does not provide an
automatic permission prompt for Full Disk Access.

Start the helper app:

```bash
open -a "$PWD/CurlSafariServer.app"
```

## Usage

Pass normal curl arguments to `curl-safari`:

```bash
bin/curl-safari -L https://www.finn.no/saved-searches
```

The CLI finds the request URL, requests matching Safari cookies from the local
helper, and passes them directly to `curl` through an anonymous pipe. Cookie
values are not written to disk or printed in normal output.

Use regular `curl` when a page does not require Safari login cookies.

## Authentication Limitations

`curl-safari` supplies Safari cookies only. It does not copy bearer tokens,
CSRF tokens, localStorage, JavaScript state, or other browser-only
authentication. A login cookie for one hostname may not authenticate an API on
another hostname.

## Security

- Only `CurlSafariServer.app` has Full Disk Access.
- The unprivileged CLI never reads Safari's cookie database.
- The Unix socket is mode `0600` and verifies the client user ID.
- Cookies are selected for the request URL's host, path, and scheme.
- Cookie data travels through the private socket and an anonymous pipe.
- Cookie values are never written to disk by `curl-safari`.
- There is no command for exporting all Safari cookies.

## Development

The implementation has two runtime components:

- `CurlSafariServer.app`: local Swift helper app with Full Disk Access. It reads
  Safari's `Cookies.binarycookies` and listens on
  `/private/tmp/curl-safari.sock`.
- `bin/curl-safari`: unprivileged Go CLI that passes ordinary curl arguments
  through unchanged.

Source code lives in `CurlSafariServer/` and `cmd/curl-safari/`. The socket path
can be overridden with `CURL_SAFARI_SOCKET_PATH` for isolated testing.

After rebuilding, restart the helper so the running process uses the new
executable:

```bash
pkill -f "$PWD/CurlSafariServer.app/Contents/MacOS/curl-safari-server" || true
open -a "$PWD/CurlSafariServer.app"
```

Run the test suites with:

```bash
go test ./...
python3 tests/test_server.py
```

The Xcode target uses automatic Apple Development signing to keep the app
identity stable across rebuilds. If the signing identity changes, macOS may
require Full Disk Access to be granted again.

## Codex Plugin Installation

Register this repository as a local marketplace and install the plugin:

```bash
codex plugin marketplace add "$PWD"
codex plugin add curl-safari@curl-safari-local
```

Reinstall the plugin after changing its manifest, skill, or assets so Codex
picks up the new cachebuster version.
