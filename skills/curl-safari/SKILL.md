---
name: curl-safari
description: Use ordinary curl commands with the user's existing Safari login. The local curl-safari CLI automatically supplies matching Safari cookies and passes normal curl arguments through unchanged. Use when Codex needs to download or inspect pages that require the user to be logged in through Safari, especially when curl is faster or more scriptable than driving a browser or Chrome, for sites such as FINN.no, account pages, saved searches, favorites, dashboards, or authenticated HTML/API endpoints.
---

# Curl Safari

Resolve `CURL_SAFARI_ROOT` to the plugin root (two directories above this
`SKILL.md`), then use `$CURL_SAFARI_ROOT/bin/curl-safari` instead of plain
`curl` when a request likely needs the user's Safari login cookies. Do not
assume a particular username or plugin installation directory.

## Workflow

1. Prefer `curl-safari` for authenticated page fetches when the user is already logged in with Safari.
2. Pass normal curl arguments through unchanged:

```bash
"$CURL_SAFARI_ROOT/bin/curl-safari" -L "https://example.com/account"
```

3. Save responses to `/private/tmp` or the active workspace when inspection is needed:

```bash
"$CURL_SAFARI_ROOT/bin/curl-safari" -L "https://example.com/account" -o /private/tmp/account.html
```

4. Use regular `curl` for public pages, unauthenticated APIs, or requests where cookies are unnecessary.

## Authenticated APIs

When a logged-in page loads data from an API on another hostname, call `curl-safari` with the API URL itself, not only the visible page URL. The tool chooses Safari cookies from the request URL hostname.

Example:

```bash
"$CURL_SAFARI_ROOT/bin/curl-safari" -L "https://api.example.com/private/routes"
```

If the API still returns 401/403, inspect whether a `Cookie` header was actually sent. A login that works on one hostname, such as `www.example.com`, may not produce any usable Safari cookies for another registrable domain or API hostname, such as `api.example.net`. In that case, `curl-safari` is working as designed but the API is not authenticated by the page host's cookies.

When 401/403 persists, check whether the API request requires non-cookie headers such as `Authorization`, CSRF tokens, `X-*` headers, or request-specific query parameters. `curl-safari` supplies Safari cookies only; it does not extract bearer tokens from JavaScript state, localStorage, or copied browser requests.

Komoot is a known example: Safari cookie auth can work for `www.komoot.com` pages while route API requests on `api.komoot.de` return `403 AccessDenied` with no usable Cookie header. For that case, prefer copied cURL from Safari Web Inspector or another way to capture the API's real auth headers.

## Server

`curl-safari` depends on the local server app:

```bash
open -a "$CURL_SAFARI_ROOT/CurlSafariServer.app"
```

Restart it with:

```bash
pkill -f curl-safari-server; open -a "$CURL_SAFARI_ROOT/CurlSafariServer.app"
```

The client receives a domain-scoped cookie jar from the server over
`/private/tmp/curl-safari.sock` and pipes it to `curl` without writing cookie
values to disk. The server creates the socket with mode `0600` and rejects
clients from other user IDs. If
the CLI reports that the socket is missing or refuses the connection, start or
restart `CurlSafariServer.app`.

If macOS denies access to Safari's cookie database, grant Full Disk Access to
`CurlSafariServer.app` under System Settings -> Privacy & Security -> Full Disk
Access, then restart the server. macOS does not provide an automatic permission
prompt for Full Disk Access. Grant access to the app bundle, not the CLI or the
inner executable.

## Cookie Safety

- Do not print, paste, summarize, or save cookie values in chat.
- Do not ask the user to copy cookies manually unless `curl-safari` cannot work.
- Do not add explicit `Cookie:` headers when `curl-safari` can provide cookies through its private socket and pipe.
- Treat downloaded authenticated pages as sensitive; store them only when needed and prefer `/private/tmp` for temporary inspection.
