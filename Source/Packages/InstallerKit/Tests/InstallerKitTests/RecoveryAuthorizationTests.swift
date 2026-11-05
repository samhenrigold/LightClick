import CryptoKit
import Foundation
import Testing

@testable import InstallerKit

extension StubbedNetwork {
    @Suite struct RecoveryAuthorizationTests {
        private static let asset = URL(string: "http://oscdn.apple.com/content/downloads/33/InstallESD.dmg")!
        private static let challenge = "0a1B2c3D"

        private func install(
            cookie: String? = "ID~\(RecoveryAuthorizationTests.challenge)",
            greetingStatus: Int = 200,
            status: Int = 200,
            body: String = "AP: x\nAU: \(RecoveryAuthorizationTests.asset)\nAT: token\n"
        ) {
            let setCookie = cookie.map { ["Set-Cookie": "session=\($0); Path=/"] } ?? [:]
            StubURLProtocol.install { request in
                request.httpMethod == "POST"
                    ? .body(body, status: status)
                    : .body("", status: greetingStatus, headers: setCookie)
            }
        }

        private func authorize() async throws(InstallerSourceError) -> [String: String] {
            try await InstallerSource.authorizationHeaders(
                for: Self.asset, makeConfiguration: StubURLProtocol.makeConfiguration)
        }

        @Test func aGoodHandshakeYieldsTheAssetTokenCookie() async throws {
            install()
            #expect(try await authorize() == ["Cookie": "AssetToken=token"])
        }

        @Test func theProofIsTheHashTheServiceExpects() async throws {
            install()
            _ = try await authorize()
            let requests = StubURLProtocol.requests
            #expect(
                requests.map(\.url?.absoluteString) == [
                    "https://osrecovery.apple.com/", "https://osrecovery.apple.com/InstallationPayload/OSInstaller"
                ])
            let post = requests[1]
            #expect(post.value(forHTTPHeaderField: "Cookie") == "session=ID~\(Self.challenge)")
            #expect(post.value(forHTTPHeaderField: "Content-Type") == "text/plain")
            let fields = String(decoding: try #require(post.httpBody), as: UTF8.self).split(separator: "\n")
            #expect(fields.count == 4)
            #expect(fields[1] == "sn=C0243070168G3M91F")
            #expect(fields[2] == "bid=Mac-3CBD00234E554E41")
            let client = try #require(fields[0].wholeMatch(of: /cid=([0-9A-F]{16})/)?.1)
            var key = bytes(client)
            key += [0x0A, 0x1B, 0x2C, 0x3D, 0x00, 0x3E, 0xE1, 0xE6, 0xAC, 0x14]
            key += SHA256.hash(data: Data("C0243070168G3M91FMac-3CBD00234E554E41".utf8))
            key += [UInt8](repeating: 0xCC, count: 10)
            #expect(fields[3] == "k=" + Fixture.sha256(Data(key)).uppercased())
        }

        private func bytes(_ hexadecimal: Substring) -> [UInt8] {
            stride(from: 0, to: hexadecimal.count, by: 2).map { offset in
                let start = hexadecimal.index(hexadecimal.startIndex, offsetBy: offset)
                return UInt8(hexadecimal[start..<hexadecimal.index(start, offsetBy: 2)], radix: 16) ?? 0
            }
        }

        @Test func otherSourcesNeedNoHandshake() async throws {
            install()
            let url = try #require(URL(string: "https://swcdn.apple.com/content/downloads/a/b.pkg"))
            let headers = try await InstallerSource.authorizationHeaders(
                for: url, makeConfiguration: StubURLProtocol.makeConfiguration)
            #expect(headers.isEmpty)
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func anUnapprovedSourceIsRefusedBeforeAnyRequest() async throws {
            install()
            let url = try #require(URL(string: "https://example.com/InstallESD.dmg"))
            await #expect(throws: InstallerSourceError.unsupportedLocation) {
                try await InstallerSource.authorizationHeaders(
                    for: url, makeConfiguration: StubURLProtocol.makeConfiguration)
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func aFailingServiceIsUnavailable() async {
            install(greetingStatus: 503)
            await #expect(throws: InstallerSourceError.recoveryUnavailable) { try await authorize() }
            install(status: 403)
            await #expect(throws: InstallerSourceError.recoveryUnavailable) { try await authorize() }
            install(body: String(repeating: "x", count: 65537))
            await #expect(throws: InstallerSourceError.recoveryUnavailable) { try await authorize() }
            StubURLProtocol.install { _ in StubResponse(error: .timedOut) }
            await #expect(throws: InstallerSourceError.recoveryUnavailable) { try await authorize() }
        }

        @Test(arguments: [nil, "nochallenge", "a~b~c", "ID~", "ID~abc", "ID~zz"] as [String?])
        func aMalformedChallengeIsRefusedBeforeAnsweringIt(_ cookie: String?) async {
            install(cookie: cookie)
            await #expect(throws: InstallerSourceError.invalidChallenge) { try await authorize() }
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test(arguments: [
            "AT: token\n",
            "AU: \(asset)\n",
            "AU: \(asset)\nAT: \n",
            "AU: \(asset)\nAT: to\u{7}ken\n",
            "AU: \(asset)\nAT: to\u{200B}ken\n".replacingOccurrences(of: "\u{200B}", with: "\u{200E}"),
            "AU: \(asset)\nAT: \(String(repeating: "x", count: 8193))\n",
            "AU: http://oscdn.apple.com/content/downloads/other/InstallESD.dmg\nAT: token\n",
            "AU: https://oscdn.apple.com/content/downloads/33/InstallESD.dmg\nAT: token\n",
            "AU: http://example.com/content/downloads/33/InstallESD.dmg\nAT: token\n",
            "AU: \(asset)?x=1\nAT: token\n"
        ])
        func anUnexpectedReplyIsRefused(_ body: String) async {
            install(body: body)
            await #expect(throws: InstallerSourceError.unexpectedInstaller) { try await authorize() }
        }

        @Test func aTokenAtTheLimitIsAccepted() async throws {
            let token = String(repeating: "x", count: 8192)
            install(body: "AU: \(Self.asset)\nAT: \(token)\n")
            #expect(try await authorize() == ["Cookie": "AssetToken=\(token)"])
        }

        @Test func theLastOfARepeatedFieldWinsAndCarriageReturnsSeparate() async throws {
            install(body: "AU: \(Self.asset)\r\nAT: first\r\nAT: second\r\n")
            #expect(try await authorize() == ["Cookie": "AssetToken=second"])
        }
    }
}
