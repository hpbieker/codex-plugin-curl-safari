import Darwin
import Foundation

let environment = ProcessInfo.processInfo.environment
let socketPath = environment["CURL_SAFARI_SOCKET_PATH"] ?? "/private/tmp/curl-safari.sock"
let maximumRequestBytes = 65_536
let clientTimeoutSeconds = max(
    1,
    Int(environment["CURL_SAFARI_CLIENT_TIMEOUT_SECONDS"] ?? "") ?? 10
)

let safariCookiePaths = [
    "\(NSHomeDirectory())/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
    "\(NSHomeDirectory())/Library/Cookies/Cookies.binarycookies",
]
let macAbsoluteTimeOffset = 978_307_200.0
let rootDir = URL(
    fileURLWithPath: environment["CURL_SAFARI_ROOT_DIR"] ?? "/private/tmp/curl-safari",
    isDirectory: true
)

struct ServerError: Error, CustomStringConvertible {
    let description: String
}

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
    let domain: String?
    let url: String?
    let ttl_seconds: Int?
}

func systemError(_ operation: String) -> ServerError {
    ServerError(description: "\(operation): \(String(cString: strerror(errno)))")
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

func matchingCookies(
    _ cookies: [SafariCookie],
    domain: String,
    requestURL: String?
) throws -> [SafariCookie] {
    var host = try normalizeDomain(domain)
    var scheme = "https"
    var path = "/"
    if let urlString = requestURL, let url = URL(string: urlString), let urlHost = url.host {
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

func ensureRootDir() throws {
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDir.path)
}

func responseData(_ response: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]))
        ?? Data("{}".utf8)
    data.append(0x0A)
    return data
}

func processRequest(_ data: Data) -> [String: Any] {
    do {
        let request = try JSONDecoder().decode(FetchRequest.self, from: data)
        if request.op == "ping" {
            return [
                "ok": true,
                "socket": socketPath,
                "server_pid": Int32(getpid()),
            ]
        }
        guard request.op == "fetch" else {
            throw NSError(domain: "curl-safari-server", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "unsupported operation: \(request.op)"
            ])
        }
        guard let domain = request.domain else {
            throw NSError(domain: "curl-safari-server", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "fetch requires domain"
            ])
        }
        let cookieFile = try resolveCookieFile()
        let ttl = request.ttl_seconds ?? 600
        guard ttl > 0 else {
            throw NSError(domain: "curl-safari-server", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "ttl_seconds must be greater than zero"
            ])
        }
        let cookies = try matchingCookies(
            parseBinaryCookies(cookieFile),
            domain: domain,
            requestURL: request.url
        )
        let output = try safeOutputPath(domain: domain)
        try writeCookieJar(cookies, to: output, ttlSeconds: ttl)
        log("wrote \(cookies.count) cookies for \(domain) to \(output.path)")
        return [
            "ok": true,
            "domain": domain,
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

func readRequest(from fileDescriptor: Int32) throws -> Data {
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)

    while true {
        let bytesRead = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if bytesRead > 0 {
            request.append(contentsOf: buffer.prefix(Int(bytesRead)))
            if request.count > maximumRequestBytes {
                throw ServerError(description: "request exceeds \(maximumRequestBytes) bytes")
            }
            if let newline = request.firstIndex(of: 0x0A) {
                request = request[..<newline]
                break
            }
        } else if bytesRead == 0 {
            break
        } else if errno != EINTR {
            throw systemError("read")
        }
    }

    guard !request.isEmpty else {
        throw ServerError(description: "empty request")
    }
    return request
}

func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(
                fileDescriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw systemError("write")
            }
        }
    }
}

func removeStaleSocket() throws {
    var info = stat()
    if lstat(socketPath, &info) == 0 {
        guard info.st_uid == geteuid() else {
            throw ServerError(description: "existing socket path is owned by another user")
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw ServerError(description: "refusing to remove non-socket path at \(socketPath)")
        }
        guard unlink(socketPath) == 0 else { throw systemError("unlink") }
    } else if errno != ENOENT {
        throw systemError("lstat")
    }
}

func createServerSocket() throws -> Int32 {
    try removeStaleSocket()

    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw systemError("socket") }
    do {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw ServerError(description: "socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in pathBytes.enumerated() {
                destination[index] = UInt8(bitPattern: byte)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw systemError("bind") }
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else { throw systemError("chmod") }
        guard Darwin.listen(fileDescriptor, 16) == 0 else { throw systemError("listen") }
        return fileDescriptor
    } catch {
        Darwin.close(fileDescriptor)
        try? FileManager.default.removeItem(atPath: socketPath)
        throw error
    }
}

func handleClient(_ fileDescriptor: Int32) {
    var noSigPipe: Int32 = 1
    _ = withUnsafePointer(to: &noSigPipe) {
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            $0,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    var timeout = timeval(tv_sec: clientTimeoutSeconds, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) {
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            $0,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
    _ = withUnsafePointer(to: &timeout) {
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            $0,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(fileDescriptor, &peerUID, &peerGID) == 0 else {
        try? writeAll(responseData(["ok": false, "error": "could not identify peer"]), to: fileDescriptor)
        return
    }
    guard peerUID == geteuid() else {
        try? writeAll(responseData(["ok": false, "error": "peer uid is not allowed"]), to: fileDescriptor)
        return
    }

    do {
        let request = try readRequest(from: fileDescriptor)
        try writeAll(responseData(processRequest(request)), to: fileDescriptor)
    } catch {
        try? writeAll(
            responseData(["ok": false, "error": String(describing: error)]),
            to: fileDescriptor
        )
    }
}

func serve() throws {
    _ = umask(0o077)
    try ensureRootDir()
    let server = try createServerSocket()
    defer {
        Darwin.close(server)
        unlink(socketPath)
    }

    log("curl-safari-server listening on \(socketPath)")
    while true {
        let client = Darwin.accept(server, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            throw systemError("accept")
        }
        autoreleasepool {
            handleClient(client)
            Darwin.close(client)
        }
    }
}

do {
    try serve()
} catch {
    fputs("curl-safari-server: \(String(describing: error))\n", stderr)
    exit(1)
}
