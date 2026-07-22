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

By default, the app uses ad hoc signing. To keep the app's signing identity
stable across rebuilds, create a local `.signing-team` file containing your
10-character Apple development team ID:

```text
ABCDE12345
```

`.signing-team` is ignored by Git. Without it, rebuilding the ad hoc-signed app
may require Full Disk Access to be granted again.

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
- Any process running as the same macOS user can connect to the helper while it
  is running.
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

When `.signing-team` exists, the Xcode target uses automatic Apple Development
signing to keep the app identity stable across rebuilds.

## Codex Plugin Installation

Register this repository as a local marketplace and install the plugin:

```bash
codex plugin marketplace add "$PWD"
codex plugin add curl-safari@curl-safari-local
```

Reinstall the plugin after changing its manifest, skill, or assets so Codex
picks up the new cachebuster version.

## Codex Plugin Releases

Version tags such as `v0.1.0` build and publish a self-contained Codex plugin
for macOS. The release ZIP contains the plugin manifest, skill, assets, a
universal `curl-safari` CLI, and a universal `CurlSafariServer.app`.

Release builds require these GitHub Actions secrets:

- `APPLE_DEVELOPER_ID_APPLICATION_P12`: base64-encoded Developer ID
  Application certificate and private key
- `APPLE_CERTIFICATE_PASSWORD`: password for the exported certificate
- `APPLE_DEVELOPER_ID_APPLICATION`: full signing identity, for example
  `Developer ID Application: Example Name (ABCDE12345)`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization
- `APPLE_TEAM_ID`: 10-character Apple developer team ID

To test the unsigned packaging flow locally:

```bash
scripts/build-release.sh 0.1.0
scripts/package-release.sh 0.1.0
```

The resulting files are written to `dist/`. Public releases are signed and
notarized by the tag-triggered GitHub Actions workflow before packaging.

## License

The code and documentation are licensed under the [MIT License](LICENSE). The
official curl brand assets have separate terms described in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support

If `curl-safari` saves you time, you can [support the project on Ko-fi](https://ko-fi.com/hpbieker).
