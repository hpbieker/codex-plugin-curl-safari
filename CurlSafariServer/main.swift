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
struct ServerError: Error, CustomStringConvertible {
    let description: String
}

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

struct FetchRequest: Decodable {
    let op: String
    let domain: String?
    let url: String?
    let cookie_scope: String?
}

func systemError(_ operation: String) -> ServerError {
    ServerError(description: "\(operation): \(String(cString: strerror(errno)))")
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
        let scope = try CookieScope(request.cookie_scope ?? "url")
        let cookieFile = try resolveCookieFile()
        let cookies = try matchingCookies(
            parseBinaryCookies(cookieFile),
            domain: domain,
            requestURL: request.url,
            scope: scope
        )
        let jar = cookieJar(cookies)
        log("returned \(cookies.count) cookies for \(domain)")
        return [
            "ok": true,
            "domain": domain,
            "cookie_jar": jar,
            "cookie_scope": scope.rawValue,
            "count": cookies.count,
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
