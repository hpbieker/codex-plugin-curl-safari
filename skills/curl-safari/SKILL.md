---
name: curl-safari
description: Use the local curl-safari CLI to fetch logged-in web pages and HTTP responses with the user's Safari cookies. Use when Codex needs to download or inspect pages that require the user to be logged in through Safari, especially when curl is faster or more scriptable than driving a browser or Chrome, for sites such as FINN.no, account pages, saved searches, favorites, dashboards, or authenticated HTML/API endpoints.
---

# Curl Safari

Use `/Users/hanspetterbieker/sources/codex-plugin-curl-safari/bin/curl-safari` instead of plain `curl` when a request likely needs the user's Safari login cookies.

## Workflow

1. Prefer `curl-safari` for authenticated page fetches when the user is already logged in with Safari.
2. Pass normal curl arguments through unchanged:

```bash
/Users/hanspetterbieker/sources/codex-plugin-curl-safari/bin/curl-safari -L "https://example.com/account"
```

3. Save responses to `/private/tmp` or the active workspace when inspection is needed:

```bash
/Users/hanspetterbieker/sources/codex-plugin-curl-safari/bin/curl-safari -L "https://example.com/account" -o /private/tmp/account.html
```

4. Use regular `curl` for public pages, unauthenticated APIs, or requests where cookies are unnecessary.

## Authenticated APIs

When a logged-in page loads data from an API on another hostname, call `curl-safari` with the API URL itself, not only the visible page URL. The tool chooses Safari cookies from the request URL hostname.

Example:

```bash
/Users/hanspetterbieker/sources/codex-plugin-curl-safari/bin/curl-safari -L "https://api.example.com/private/routes"
```

If the API still returns 401/403, inspect whether a `Cookie` header was actually sent. A login that works on one hostname, such as `www.example.com`, may not produce any usable Safari cookies for another registrable domain or API hostname, such as `api.example.net`. In that case, `curl-safari` is working as designed but the API is not authenticated by the page host's cookies.

When 401/403 persists, check whether the API request requires non-cookie headers such as `Authorization`, CSRF tokens, `X-*` headers, or request-specific query parameters. `curl-safari` supplies Safari cookies only; it does not extract bearer tokens from JavaScript state, localStorage, or copied browser requests.

Komoot is a known example: Safari cookie auth can work for `www.komoot.com` pages while route API requests on `api.komoot.de` return `403 AccessDenied` with no usable Cookie header. For that case, prefer copied cURL from Safari Web Inspector or another way to capture the API's real auth headers.

## Server

`curl-safari` depends on the local server app:

```bash
open -a "/Users/hanspetterbieker/sources/codex-plugin-curl-safari/CurlSafariServer.app"
```

Restart it with:

```bash
pkill -f curl-safari-server; open -a "/Users/hanspetterbieker/sources/codex-plugin-curl-safari/CurlSafariServer.app"
```

The client talks to the server over `/private/tmp/curl-safari.sock`. The server
creates the socket with mode `0600` and rejects clients from other user IDs. If
the CLI reports that the socket is missing or refuses the connection, start or
restart `CurlSafariServer.app`; do not create request files under
`/private/tmp/curl-safari`.

If macOS denies access to Safari's cookie database, grant Full Disk Access to
`CurlSafariServer.app` under System Settings -> Privacy & Security -> Full Disk
Access, then restart the server. macOS does not provide an automatic permission
prompt for Full Disk Access. Grant access to the app bundle, not the CLI or the
inner executable.

## Cookie Safety

- Do not print, paste, summarize, or save cookie values in chat.
- Do not ask the user to copy cookies manually unless `curl-safari` cannot work.
- Do not add explicit `Cookie:` headers when `curl-safari` can provide cookies through its temporary cookie jar.
- Treat downloaded authenticated pages as sensitive; store them only when needed and prefer `/private/tmp` for temporary inspection.
