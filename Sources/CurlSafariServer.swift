import Foundation

let safariCookiePaths = [
    "\(NSHomeDirectory())/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
    "\(NSHomeDirectory())/Library/Cookies/Cookies.binarycookies",
]
let macAbsoluteTimeOffset = 978_307_200.0
let rootDir = URL(fileURLWithPath: "/private/tmp/curl-safari", isDirectory: true)
let requestDir = rootDir.appendingPathComponent("requests", isDirectory: true)
let responseDir = rootDir.appendingPathComponent("responses", isDirectory: true)

func log(_ message: String) {
    print(message)
    fflush(stdout)
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

struct FetchRequest: Decodable {
    let op: String
    let domain: String
    let url: String?
    let ttl_seconds: Int?
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

func readCString(_ data: Data, _ offset: Int) -> String {
    guard offset > 0 && offset < data.count else { return "" }
    var end = offset
    while end < data.count && data[end] != 0 {
        end += 1
    }
    return String(data: data[offset..<end], encoding: .utf8) ?? ""
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
    let domain = readCString(data, domainOffset)
    let name = readCString(data, nameOffset)
    if domain.isEmpty || name.isEmpty { return nil }
    let path = readCString(data, pathOffset)
    return SafariCookie(
        domain: domain,
        name: name,
        path: path.isEmpty ? "/" : path,
        value: readCString(data, valueOffset),
        flags: flags,
        expiresAt: macTimeToUnix(expiresRaw),
        createdAt: macTimeToUnix(createdRaw)
    )
}

func resolveCookieFile() throws -> URL {
    for path in safariCookiePaths {
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
    }
    throw NSError(domain: "curl-safari-server", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "could not find Safari Cookies.binarycookies"
    ])
}

func parseBinaryCookies(_ url: URL) throws -> [SafariCookie] {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw NSError(domain: "curl-safari-server", code: 5, userInfo: [
            NSLocalizedDescriptionKey: """
            macOS denied access to \(url.path). Full Disk Access is not granted via an automatic prompt for this CLI helper. Add curl-safari-server manually in System Settings -> Privacy & Security -> Full Disk Access, then restart the server.
            """
        ])
    }
    guard data.count >= 8 && String(data: data[0..<4], encoding: .ascii) == "cook" else {
        throw NSError(domain: "curl-safari-server", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "\(url.path) is not a Safari binary cookie file"
        ])
    }
    let pageCount = Int(try readUInt32BE(data, 4))
    var pageDataOffset = 8 + pageCount * 4
    var cookies: [SafariCookie] = []
    for pageIndex in 0..<pageCount {
        let pageSize = Int(try readUInt32BE(data, 8 + pageIndex * 4))
        guard pageDataOffset + pageSize <= data.count else { break }
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
    return host == cd || host.hasSuffix("." + cd)
}

func pathMatches(cookiePath: String, requestPath: String) -> Bool {
    let requestPath = requestPath.isEmpty ? "/" : requestPath
    if requestPath == cookiePath { return true }
    if requestPath.hasPrefix(cookiePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") {
        return true
    }
    if cookiePath == "/" { return true }
    return requestPath.hasPrefix(cookiePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
}

func matchingCookies(_ cookies: [SafariCookie], request: FetchRequest) throws -> [SafariCookie] {
    var host = try normalizeDomain(request.domain)
    var scheme = "https"
    var path = "/"
    if let urlString = request.url, let url = URL(string: urlString), let urlHost = url.host {
        host = urlHost.lowercased()
        scheme = url.scheme?.lowercased() ?? "https"
        path = url.path.isEmpty ? "/" : url.path
    }
    return cookies.filter { cookie in
        !cookie.expired
            && domainMatches(cookieDomain: cookie.domain, host: host)
            && pathMatches(cookiePath: cookie.path, requestPath: path)
            && (scheme == "https" || !cookie.secure)
    }.sorted {
        if $0.domain != $1.domain { return $0.domain < $1.domain }
        if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
        return $0.name < $1.name
    }
}

func cookieExpiry(_ cookie: SafariCookie, ttlSeconds: Int) -> Int {
    let ttlExpiry = Int(Date().timeIntervalSince1970) + ttlSeconds
    if cookie.expiresAt <= 0 { return ttlExpiry }
    return min(Int(cookie.expiresAt), ttlExpiry)
}

func boolText(_ value: Bool) -> String {
    value ? "TRUE" : "FALSE"
}

func safeOutputPath(domain: String) throws -> URL {
    let normalized = try normalizeDomain(domain)
    return rootDir.appendingPathComponent("\(normalized).cookies")
}

func writeCookieJar(_ cookies: [SafariCookie], to output: URL, ttlSeconds: Int) throws {
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDir.path)
    var lines = [
        "# Netscape HTTP Cookie File",
        "# Generated by curl-safari-server. Do not commit this file.",
    ]
    for cookie in cookies {
        let httpOnlyPrefix = cookie.httpOnly ? "#HttpOnly_" : ""
        let includeSubdomains = cookie.domain.hasPrefix(".")
        lines.append([
            httpOnlyPrefix + cookie.domain,
            boolText(includeSubdomains),
            cookie.path,
            boolText(cookie.secure),
            String(cookieExpiry(cookie, ttlSeconds: ttlSeconds)),
            cookie.name,
            cookie.value,
        ].joined(separator: "\t"))
    }
    let tmp = output.appendingPathExtension("tmp")
    try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
    if FileManager.default.fileExists(atPath: output.path) {
        try FileManager.default.removeItem(at: output)
    }
    try FileManager.default.moveItem(at: tmp, to: output)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
}

func ensureDirs() throws {
    for dir in [rootDir, requestDir, responseDir] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}

func responseJSON(_ response: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
}

func processRequest(at processingURL: URL) -> [String: Any] {
    do {
        let data = try Data(contentsOf: processingURL)
        let request = try JSONDecoder().decode(FetchRequest.self, from: data)
        guard request.op == "fetch" else {
            throw NSError(domain: "curl-safari-server", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "unsupported operation"
            ])
        }
        let cookieFile = try resolveCookieFile()
        let ttl = request.ttl_seconds ?? 600
        let cookies = try matchingCookies(parseBinaryCookies(cookieFile), request: request)
        let output = try safeOutputPath(domain: request.domain)
        try writeCookieJar(cookies, to: output, ttlSeconds: ttl)
        log("wrote \(cookies.count) cookies for \(request.domain) to \(output.path)")
        return [
            "ok": true,
            "domain": request.domain,
            "path": output.path,
            "count": cookies.count,
            "ttl_seconds": ttl,
            "server_pid": Int32(getpid()),
        ]
    } catch {
        return [
            "ok": false,
            "error": error.localizedDescription,
            "server_pid": Int32(getpid()),
        ]
    }
}

func serve() throws {
    try ensureDirs()
    log("curl-safari-server watching \(requestDir.path)")
    while true {
        autoreleasepool {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: requestDir,
                includingPropertiesForKeys: nil
            )) ?? []
            for requestURL in files where requestURL.lastPathComponent.hasSuffix(".request.json") {
                let requestID = requestURL.lastPathComponent.components(separatedBy: ".").first ?? UUID().uuidString
                let processingURL = requestDir.appendingPathComponent("\(requestID).processing")
                do {
                    try FileManager.default.moveItem(at: requestURL, to: processingURL)
                } catch {
                    continue
                }
                let response = processRequest(at: processingURL)
                let responseURL = responseDir.appendingPathComponent("\(requestID).response.json")
                let tmpResponseURL = responseURL.appendingPathExtension("tmp")
                do {
                    var data = responseJSON(response)
                    data.append(0x0A)
                    try data.write(to: tmpResponseURL, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpResponseURL.path)
                    if FileManager.default.fileExists(atPath: responseURL.path) {
                        try FileManager.default.removeItem(at: responseURL)
                    }
                    try FileManager.default.moveItem(at: tmpResponseURL, to: responseURL)
                    try? FileManager.default.removeItem(at: processingURL)
                } catch {
                    log("failed to write response: \(error.localizedDescription)")
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

func checkAccess() -> Int32 {
    let executable = CommandLine.arguments.first ?? "(unknown)"
    print("executable=\(executable)")
    do {
        let cookieFile = try resolveCookieFile()
        print("cookie_file=\(cookieFile.path)")
        _ = try Data(contentsOf: cookieFile)
        print("access=ok")
        return 0
    } catch {
        print("access=denied")
        print("error=\(error.localizedDescription)")
        return 1
    }
}

if CommandLine.arguments.dropFirst().contains("--check-access") {
    exit(checkAccess())
}

do {
    try serve()
} catch {
    fputs("curl-safari-server: \(error.localizedDescription)\n", stderr)
    exit(1)
}
