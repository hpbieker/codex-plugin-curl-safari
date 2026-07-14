# Curl Safari

Use Safari cookies with `curl` without giving Codex or other sandboxed clients
Full Disk Access.

## Components

- `CurlSafariServer.app`: privileged Swift server app. This is the only
  process that reads Safari's `Cookies.binarycookies`.
- `bin/curl-safari`: unprivileged Go CLI. It calls `curl` with a temporary
  domain-scoped cookie jar from the server.
- `cmd/curl-safari/`: Go source for the CLI.
- `Sources/CurlSafariServer.swift`: Swift source for the server app.

## Build

```bash
./build.sh
```

Requires Swift and Go.

## Full Disk Access

Give Full Disk Access to `CurlSafariServer.app`:

```text
System Settings -> Privacy & Security -> Full Disk Access
```

Use the app bundle, not the inner executable.

## Start Server

```bash
open -a "$PWD/CurlSafariServer.app"
```

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
- CLI does not need Full Disk Access
- no export-all command
- cookie jars are domain scoped
- cookie jars are written with `0600`
- default jar TTL is 600 seconds
- normal CLI output never prints cookie values
