import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Serialize read/modify/write across both threads and the containing App/extension.
enum SharedFileLock {
    private static let local = NSRecursiveLock()
    static func perform<T>(at url: URL, _ body: () throws -> T) throws -> T {
        local.lock(); defer { local.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
