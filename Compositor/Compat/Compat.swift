import Foundation

// Compatibility shims for APIs that arrived after macOS 12 / Swift 5.9.
//
// The app was written against macOS 26 and Swift 6. These bring the pieces it
// relies on down to the Swift 5.7 toolchain and the macOS 12 runtime without
// changing call sites.

/// Swift's `Mutex` (macOS 15) replaced by a lock around the same storage.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

extension NSLocking {
    /// `NSLock.withLock` arrived with macOS 13; the call sites only need the lock/unlock pair.
    @discardableResult
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension MainActor {
    /// Runs a closure that is known to already be on the main thread.
    ///
    /// `MainActor.assumeIsolated` arrived with Swift 5.9. Actor isolation is a
    /// compile-time property, so the closure's runtime representation is the
    /// same as an unannotated one; the callbacks that use this (event monitors,
    /// notification handlers, main-queue dispatch) all run on the main thread.
    @inline(__always)
    static func assumeIsolated<Result>(_ operation: @MainActor () throws -> Result) rethrows -> Result {
        typealias Operation = () throws -> Result
        return try withoutActuallyEscaping(operation) { escapable in
            try unsafeBitCast(escapable, to: Operation.self)()
        }
    }
}
