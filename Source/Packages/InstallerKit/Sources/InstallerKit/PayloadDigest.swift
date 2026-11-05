import CryptoKit
import Foundation

/// A payload's SHA-256 digest. Catalogs may spell it in either case; two digests compare by value.
public struct PayloadDigest: Hashable, Sendable, CustomStringConvertible {
    /// Uppercase hexadecimal.
    public let description: String

    public init?(hexadecimal text: String) {
        guard text.utf16.count == 64, text.utf8.allSatisfy(\.isHexDigit) else { return nil }
        description = text.uppercased()
    }

    /// Hashes a file through a bounded buffer, refusing to follow a symlink at `file`.
    static func ofFile(at file: URL) throws(InstallerSourceError) -> PayloadDigest {
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw .unreadableDownload }
        defer { close(descriptor) }
        var hash = SHA256()
        let succeeded = withUnsafeTemporaryAllocation(byteCount: 65536, alignment: 1) { buffer -> Bool in
            while true {
                let count = read(descriptor, buffer.baseAddress, buffer.count)
                if count > 0 {
                    hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
                } else if count == 0 {
                    return true
                } else if errno != EINTR {
                    return false
                }
            }
        }
        guard succeeded else { throw .unverifiableDownload }
        return PayloadDigest(hexadecimal: hash.finalize().map { String(format: "%02X", $0) }.joined())!
    }
}

extension UInt8 {
    fileprivate var isHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}
