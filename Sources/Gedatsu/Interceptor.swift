import Foundation

internal typealias InterceptType = (() -> Void)

internal enum Interception {
    case passthrough
    case pending
    case schedule(InterceptType)
}

internal protocol Interceptor {
    func save(closure: @escaping InterceptType)
    func prepareInterception() -> Interception
    func completeInterception()
}

internal class InterceptorImpl: Interceptor {
    private let lock = NSLock()
    private var queue: [InterceptType] = []
    // A warning can span several stderr reads before its formatter finishes.
    private var scheduledCount = 0

    func save(closure: @escaping InterceptType) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(closure)
    }

    func prepareInterception() -> Interception {
        lock.lock()
        defer { lock.unlock() }
        if !queue.isEmpty {
            scheduledCount += 1
            return .schedule(queue.removeFirst())
        }
        return scheduledCount > 0 ? .pending : .passthrough
    }

    func completeInterception() {
        lock.lock()
        defer { lock.unlock() }
        scheduledCount -= 1
    }
}
