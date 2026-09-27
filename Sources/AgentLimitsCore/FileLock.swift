import Foundation

/// An exclusive advisory lock on a file, held from init until unlock(). Blocks
/// while another process holds it (only ever for the length of one refresh).
final class FileLock {
    private var fd: Int32

    init(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
    }

    func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
