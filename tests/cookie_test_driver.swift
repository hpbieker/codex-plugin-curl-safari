import Foundation

// Compile with the production Cookies.swift. Inputs are synthetic fixtures;
// this executable never searches for or reads the user's Safari cookies.
@main
enum CookieTestDriver {
    static func main() {
        do {
            let args = CommandLine.arguments
            let cookies = try parseBinaryCookies(URL(fileURLWithPath: args[1]))
            let scope = try CookieScope(args[4])
            let selected = try matchingCookies(cookies, domain: args[2], requestURL: args[3], scope: scope)
            let result: [String: Any] = [
                "parsed": cookies.map { cookie in
                    ["domain": cookie.domain, "name": cookie.name, "path": cookie.path,
                     "value": cookie.value, "secure": cookie.secure, "httpOnly": cookie.httpOnly,
                     "expiresAt": cookie.expiresAt, "createdAt": cookie.createdAt] as [String: Any]
                },
                "selected": selected.map { $0.name },
                "jar": cookieJar(selected),
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
