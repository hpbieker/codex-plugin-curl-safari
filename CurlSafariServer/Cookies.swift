import Foundation

let macAbsoluteTimeOffset = 978_307_200.0

enum CookieScope: String {
    case url
    case host

    init(_ value: String) throws {
        guard let scope = CookieScope(rawValue: value) else {
            throw NSError(domain: "curl-safari-server", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "unsupported cookie scope"
            ])
        }
        self = scope
    }
}

struct SafariCookie {
    let domain: String
    let name: String
    let path: String
    let value: String
    let flags: UInt32
    let expiresAt: Double
    let createdAt: Double

    var secure: Bool { (flags & 1) != 0 }
    var httpOnly: Bool { (flags & 4) != 0 }
    var expired: Bool { expiresAt > 0 && expiresAt <= Date().timeIntervalSince1970 }
}

func readUInt32BE(_ data: Data, _ offset: Int) throws -> UInt32 {
    guard offset + 4 <= data.count else { throw NSError(domain: "bounds", code: 1) }
    return data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

func readUInt32LE(_ data: Data, _ offset: Int) throws -> UInt32 {
    guard offset + 4 <= data.count else { throw NSError(domain: "bounds", code: 1) }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

func readDoubleLE(_ data: Data, _ offset: Int) throws -> Double {
    guard offset + 8 <= data.count else { throw NSError(domain: "bounds", code: 1) }
    var bits: UInt64 = 0
    for index in 0..<8 {
        bits |= UInt64(data[offset + index]) << UInt64(index * 8)
    }
    return Double(bitPattern: bits)
}

func readCString(_ data: Data, _ offset: Int) -> String? {
    guard offset >= 56 && offset < data.count else { return nil }
    var end = offset
    while end < data.count && data[end] != 0 {
        end += 1
    }
    guard end < data.count else { return nil }
    return String(data: data[offset..<end], encoding: .utf8)
}

func macTimeToUnix(_ value: Double) -> Double {
    if value <= 0 { return 0 }
    return value + macAbsoluteTimeOffset
}

func parseCookieRecord(_ page: Data, _ offset: Int) -> SafariCookie? {
    guard offset >= 0 && offset + 56 <= page.count else { return nil }
    guard let size = try? Int(readUInt32LE(page, offset)), size > 0, offset + size <= page.count else {
        return nil
    }
    let record = page[offset..<offset + size]
    let data = Data(record)
    guard
        let flags = try? readUInt32LE(data, 8),
        let domainOffset = try? Int(readUInt32LE(data, 16)),
        let nameOffset = try? Int(readUInt32LE(data, 20)),
        let pathOffset = try? Int(readUInt32LE(data, 24)),
        let valueOffset = try? Int(readUInt32LE(data, 28)),
        let expiresRaw = try? readDoubleLE(data, 40),
        let createdRaw = try? readDoubleLE(data, 48)
    else {
        return nil
    }
    guard
        let domain = readCString(data, domainOffset),
        let name = readCString(data, nameOffset),
        let path = readCString(data, pathOffset),
        let value = readCString(data, valueOffset),
        !domain.isEmpty, !name.isEmpty,
        expiresRaw.isFinite, createdRaw.isFinite,
        macTimeToUnix(expiresRaw) < Double(Int.max),
        [domain, name, path, value].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil })
    else { return nil }
    return SafariCookie(
        domain: domain,
        name: name,
        path: path.isEmpty ? "/" : path,
        value: value,
        flags: flags,
        expiresAt: macTimeToUnix(expiresRaw),
        createdAt: macTimeToUnix(createdRaw)
    )
}

func parseBinaryCookies(_ url: URL) throws -> [SafariCookie] {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw NSError(domain: "curl-safari-server", code: 5, userInfo: [
            NSLocalizedDescriptionKey: """
            macOS denied access to \(url.path). Grant Full Disk Access to CurlSafariServer.app in System Settings -> Privacy & Security -> Full Disk Access, then restart the server.
            """
        ])
    }
    guard data.count >= 8 && String(data: data[0..<4], encoding: .ascii) == "cook" else {
        throw NSError(domain: "curl-safari-server", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "\(url.path) is not a Safari binary cookie file"
        ])
    }
    let pageCount = Int(try readUInt32BE(data, 4))
    guard pageCount <= (data.count - 8) / 4 else {
        throw NSError(domain: "curl-safari-server", code: 2)
    }
    var pageDataOffset = 8 + pageCount * 4
    var cookies: [SafariCookie] = []
    for pageIndex in 0..<pageCount {
        let pageSize = Int(try readUInt32BE(data, 8 + pageIndex * 4))
        guard pageDataOffset + pageSize <= data.count else {
            throw NSError(domain: "curl-safari-server", code: 2)
        }
        let page = Data(data[pageDataOffset..<pageDataOffset + pageSize])
        pageDataOffset += pageSize
        if page.count < 8 { continue }
        let cookieCount = Int((try? readUInt32LE(page, 4)) ?? 0)
        for cookieIndex in 0..<cookieCount {
            let offsetPosition = 8 + cookieIndex * 4
            if offsetPosition + 4 > page.count { break }
            let cookieOffset = Int((try? readUInt32LE(page, offsetPosition)) ?? 0)
            if let cookie = parseCookieRecord(page, cookieOffset) {
                cookies.append(cookie)
            }
        }
    }
    return cookies
}

func normalizeDomain(_ value: String) throws -> String {
    var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") {
        candidate = URL(string: candidate)?.host ?? ""
    }
    candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
    if candidate.isEmpty || candidate.rangeOfCharacter(from: allowed.inverted) != nil || candidate.contains("..") {
        throw NSError(domain: "curl-safari-server", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "invalid domain: \(value)"
        ])
    }
    return candidate
}

func domainMatches(cookieDomain: String, host: String) -> Bool {
    let cd = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    let host = host.lowercased()
    if cookieDomain.hasPrefix(".") {
        return host == cd || host.hasSuffix("." + cd)
    }
    return host == cd
}

func pathMatches(cookiePath: String, requestPath: String) -> Bool {
    let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
    let requestPath = requestPath.isEmpty ? "/" : requestPath
    if requestPath == cookiePath { return true }
    if cookiePath == "/" { return true }
    return requestPath.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
}

func matchingCookies(
    _ cookies: [SafariCookie],
    domain: String,
    requestURL: String?,
    scope: CookieScope = .url
) throws -> [SafariCookie] {
    var host = try normalizeDomain(domain)
    var scheme = "https"
    var path = "/"
    if let urlString = requestURL {
        guard let url = URLComponents(string: urlString), let urlHost = url.host,
              let urlScheme = url.scheme?.lowercased(), ["http", "https"].contains(urlScheme),
              try normalizeDomain(urlHost) == host else {
            throw NSError(domain: "curl-safari-server", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "request URL must be HTTP(S) and match the requested domain"
            ])
        }
        host = try normalizeDomain(urlHost)
        scheme = urlScheme
        path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
    }
    return cookies.filter { cookie in
        !cookie.expired
            && domainMatches(cookieDomain: cookie.domain, host: host)
            // curl needs the original host's cookies for subsequent paths
            // and HTTP -> HTTPS redirects. It enforces these attributes on
            // each outgoing request using the unmodified cookie jar.
            && (scope == .host || pathMatches(cookiePath: cookie.path, requestPath: path))
            && (scope == .host || scheme == "https" || !cookie.secure)
    }.sorted {
        if $0.domain != $1.domain { return $0.domain < $1.domain }
        if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
        return $0.name < $1.name
    }
}

func cookieExpiry(_ cookie: SafariCookie) -> Int {
    if cookie.expiresAt <= 0 { return 0 }
    return Int(cookie.expiresAt)
}

func boolText(_ value: Bool) -> String {
    value ? "TRUE" : "FALSE"
}

func cookieJar(_ cookies: [SafariCookie]) -> String {
    var lines = [
        "# Netscape HTTP Cookie File",
        "# Generated in memory by curl-safari-server.",
    ]
    for cookie in cookies {
        let httpOnlyPrefix = cookie.httpOnly ? "#HttpOnly_" : ""
        let includeSubdomains = cookie.domain.hasPrefix(".")
        lines.append([
            httpOnlyPrefix + cookie.domain,
            boolText(includeSubdomains),
            cookie.path,
            boolText(cookie.secure),
            String(cookieExpiry(cookie)),
            cookie.name,
            cookie.value,
        ].joined(separator: "\t"))
    }
    return lines.joined(separator: "\n") + "\n"
}
