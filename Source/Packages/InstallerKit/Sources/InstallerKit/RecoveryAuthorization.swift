// The handshake with Apple's recovery service that yields the Mavericks asset token. Session cookies and tokens are
// ephemeral and never written to a journal or receipt.
import CryptoKit
import Foundation
import Security

extension InstallerSource {
    /// The request headers `url` needs: none, except the recovery asset's token.
    ///
    /// - Parameter makeConfiguration: The base session configuration, which tests replace with a stub.
    public static func authorizationHeaders(
        for url: URL,
        makeConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) async throws(InstallerSourceError) -> [String: String] {
        guard isApproved(url) else { throw .unsupportedLocation }
        guard isMavericksRecoveryAsset(url) else { return [:] }
        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let root = URL(string: "https://osrecovery.apple.com/")!
        let (_, greeting) = try await exchange(URLRequest(url: root), session: session)
        let headers = greeting.allHeaderFields as? [String: String] ?? [:]
        let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: root).last { $0.name == "session" }?
            .value
        let parts = cookie?.components(separatedBy: "~") ?? []
        var random = [UInt8](repeating: 0, count: 8)
        guard let cookie, parts.count == 2, let challenge = bytes(hexadecimal: parts[1]), !challenge.isEmpty,
            SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess
        else { throw .invalidChallenge }

        var request = URLRequest(url: URL(string: "https://osrecovery.apple.com/InstallationPayload/OSInstaller")!)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("session=\(cookie)", forHTTPHeaderField: "Cookie")
        // Public recovery-compatible identifiers supplied by Mavericks Forever, not this host's hardware identity.
        let board = "Mac-3CBD00234E554E41"
        let serial = "C0243070168G3M91F"
        var key = random + challenge + [0x00, 0x3E, 0xE1, 0xE6, 0xAC, 0x14]
        key += SHA256.hash(data: Data((serial + board).utf8))
        key += [UInt8](repeating: 0xCC, count: 10)
        let proof = hexadecimal(SHA256.hash(data: key))
        request.httpBody = Data("cid=\(hexadecimal(random))\nsn=\(serial)\nbid=\(board)\nk=\(proof)".utf8)
        let (body, _) = try await exchange(request, session: session)

        var fields: [String: String] = [:]
        for line in (String(data: body, encoding: .utf8) ?? "").components(separatedBy: .newlines) {
            guard let colon = line.range(of: ": ") else { continue }
            fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
        }
        // Retain Apple's exact asset, never one the service substitutes. The token goes in a header: no control
        // characters, so a response can't inject another one.
        guard let asset = URLComponents(string: fields["AU"] ?? "")?.url, isMavericksRecoveryAsset(asset), asset == url,
            let token = fields["AT"], (1...8192).contains(token.utf16.count),
            token.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw .unexpectedInstaller }
        return ["Cookie": "AssetToken=\(token)"]
    }

    /// Small control messages only. Large downloads use InstallerDownload's streaming transfer.
    private static func exchange(
        _ request: URLRequest, session: URLSession
    ) async throws(InstallerSourceError) -> (Data, HTTPURLResponse) {
        guard let (body, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200, body.count <= 65536
        else { throw .recoveryUnavailable }
        return (body, http)
    }

    private static func bytes(hexadecimal text: String) -> [UInt8]? {
        let digits = text.utf8.map { Character(UnicodeScalar($0)).hexDigitValue.map { UInt8($0) } }
        guard digits.count.isMultiple(of: 2), digits.allSatisfy({ $0 != nil }) else { return nil }
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0]! << 4 | digits[$0 + 1]! }
    }

    private static func hexadecimal(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
