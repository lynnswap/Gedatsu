import Foundation

internal typealias InterceptType = (() -> Void)

internal protocol Interceptor {
    func save(closure: @escaping InterceptType)
    func takeNext() -> InterceptType?
}

internal class InterceptorImpl: Interceptor {
    private let lock = NSLock()
    private var queue: [InterceptType] = []

    func save(closure: @escaping InterceptType) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(closure)
    }

    func takeNext() -> InterceptType? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}
