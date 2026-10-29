# Curl Safari for Codex

Fetch authenticated web pages from Codex using your existing Safari login.
Curl Safari provides a local `curl-safari` command that supplies matching
Safari cookies to curl, with a separate helper app that reads the cookies.

You can also use the command directly from a terminal without Codex.

## Features

- **Use your Safari login:** Make authenticated requests without copying cookies
  manually or entering your website password again.
- **Use curl options:** Save responses, set request headers, and submit data
  with familiar curl arguments.
- **Keep cookie handling local:** Transfer cookies through a private Unix socket
  and an anonymous pipe rather than a temporary cookie file.
- **Limit Full Disk Access:** Grant access to the helper app while keeping the
  CLI and Codex unprivileged.

## Requirements

- macOS 14 or later and Safari.
- A website account signed in through Safari for authenticated requests.
- Xcode with its command-line tools and Go 1.22 or later to build from source.
- Codex with plugin support to use the included skill.

Only macOS is supported. Signing in through another browser does not provide
authentication to this tool.

## Installation

Clone the repository and build the helper app and CLI:

```sh
git clone https://github.com/hpbieker/codex-plugin-curl-safari.git
cd codex-plugin-curl-safari
./build.sh
```

Give `CurlSafariServer.app` **Full Disk Access** in **System Settings → Privacy
& Security → Full Disk Access**. Add the app bundle from the repository, then
open it:

```sh
open -a "$PWD/CurlSafariServer.app"
```

macOS does not show an automatic Full Disk Access prompt. Grant access to the
app bundle, not its inner executable or the CLI. The helper registers to launch
at login; macOS may require approval under **System Settings → General → Login
Items**.

To use the plugin in Codex, register the repository's local marketplace:

```sh
codex plugin marketplace add .
codex plugin add curl-safari@curl-safari-local
```

Keep the repository in its chosen location after setup. If you rebuild the
helper with the default ad hoc signature, macOS may require you to grant Full
Disk Access again. See [Development](#development) for signing options.

## Usage

Ask Codex in natural language. For example:

> Fetch this page using my existing Safari login.

> Save my account page to a temporary file for inspection.

> Check whether my Safari login authenticates this API endpoint.

From a terminal, run the CLI from the repository root:

```sh
bin/curl-safari https://example.com/account
bin/curl-safari https://example.com/account -o /private/tmp/account.html
```

Replace the example URL with a website where you are signed in through Safari.
Use regular `curl` for public pages that do not need login cookies.

The CLI starts the bundled helper if its socket is missing or refuses a
connection, then retries briefly. Requests use the permissions of your signed-in
account, including when you use curl options that change remote data.

## Privacy and account access

The helper reads Safari's `Cookies.binarycookies` and selects cookies for the
requested host, path, and scheme. The CLI receives them through a Unix socket
at `/private/tmp/curl-safari.sock` and passes them to curl through an anonymous
pipe. The tool does not ask for your website passwords.

The socket has mode `0600`, and the helper checks that clients have the same
user ID. **Any process running as your macOS user can request cookies from the
helper while it is running.** Full Disk Access is a broad permission; grant it
only to a build you trust.

Cookie values are not written to disk or printed during normal operation.
Curl options such as verbose logging, tracing, or cookie-jar output can expose
or save them. Downloaded account pages can contain private information, and
content read by Codex becomes available to the conversation.

## Limitations

- Authentication uses cookies only. Bearer tokens, CSRF tokens, localStorage,
  and other browser state are not extracted.
- A login on one hostname may not authenticate an API on another hostname.
  Use the API URL itself when checking API access.
- Cookie selection uses the initial URL. Redirects to another host or path can
  require cookies that were not included in the initial selection.
- The CLI currently detects the first standalone `http://` or `https://`
  argument. Put the target URL before other URL-valued arguments; the
  `--url=https://…` form is not supported.
- The curl `-q` option currently does not suppress loading `.curlrc` through
  this wrapper.
- Safari profiles and private browsing are not explicitly supported. The
  helper reads the standard Safari cookie-file locations.

## Troubleshooting

If cookie access is denied, check the helper's Full Disk Access permission and
restart it. From the repository root:

```sh
pkill -f "$PWD/CurlSafariServer.app/Contents/MacOS/curl-safari-server" || true
open -a "$PWD/CurlSafariServer.app"
```

If a request returns `401` or `403`, confirm that you are signed in to the
requested hostname in Safari. The endpoint may also require authentication
headers or browser state that this tool does not supply.

## Development

The Swift helper source is in `CurlSafariServer/`; the Go CLI is in
`cmd/curl-safari/`. Agent usage instructions are in
[`skills/curl-safari/SKILL.md`](skills/curl-safari/SKILL.md).

Run the test suites from the repository root:

```sh
go test ./...
python3 tests/test_server.py
```

The tests use local servers and isolated sockets. The Python suite builds the
Swift helper and requires Xcode. Set `CURL_SAFARI_SOCKET_PATH` in both client
and helper environments to use a different socket for development.

For a stable signing identity across rebuilds, create a Git-ignored
`.signing-team` file containing your 10-character Apple development team ID:

```text
ABCDE12345
```

The build then uses automatic Apple Development signing. Without this file,
it uses ad hoc signing. Restart the helper after rebuilding so it runs the new
executable. Reinstall the Codex plugin after changing its manifest, skill, or
assets to refresh the installed copy.

See [Releasing](docs/releasing.md) for universal builds, distribution signing,
notarization, and GitHub Actions configuration.

## License

Code and documentation are licensed under the [MIT License](LICENSE). The
official curl brand assets have separate terms described in
[Third-party notices](THIRD_PARTY_NOTICES.md).

## Support

If Curl Safari saves you time, you can [support the project on Ko-fi](https://ko-fi.com/hpbieker).
