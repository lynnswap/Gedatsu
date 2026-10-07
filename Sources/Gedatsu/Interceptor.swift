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
    func completeInterception() -> InterceptType?
}

internal class InterceptorImpl: Interceptor {
    private let lock = NSLock()
    private var queue: [InterceptType] = []
    // A warning can span several stderr reads before its formatter finishes.
    private var isIntercepting = false

    func save(closure: @escaping InterceptType) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(closure)
    }

    func prepareInterception() -> Interception {
        lock.lock()
        defer { lock.unlock() }
        if isIntercepting { return .pending }
        guard !queue.isEmpty else { return .passthrough }
        isIntercepting = true
        return .schedule(queue.removeFirst())
    }

    func completeInterception() -> InterceptType? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else {
            isIntercepting = false
            return nil
        }
        return queue.removeFirst()
    }
}
