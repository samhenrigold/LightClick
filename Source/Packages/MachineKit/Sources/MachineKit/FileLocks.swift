import Foundation

/// Exclusive, non-blocking advisory locks, held until `release()`. They are the same `flock`s VIMSession and VIMMachine
/// take on a package, so holding one proves no other process is using it.
struct FileLocks {
    private var descriptors: [Int32] = []

    /// False if the file can't be opened, isn't a plain file with one link, or someone else holds it. The file is
    /// created if it's missing, but its folder must exist.
    mutating func acquire(_ url: URL) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard descriptor >= 0 else { return false }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            close(descriptor)
            return false
        }
        descriptors.append(descriptor)
        return true
    }

    mutating func release() {
        descriptors.forEach { close($0) }
        descriptors = []
    }
}
