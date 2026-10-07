import Foundation
import XCTest
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import Gedatsu

internal extension ViewType {
    func callLayout() {
        #if os(iOS)
        setNeedsLayout()
        layoutIfNeeded()
        #elseif os(macOS)
        needsLayout = true
        layoutSubtreeIfNeeded()
        #endif
    }
}

final class GedatsuTests: XCTestCase {
    func testSplitWarningReadsStaySuppressedUntilFormattingCompletes() {
        let finished = expectation(description: "Suppress split warning reads until its diagnostic completes")
        DispatchQueue.main.async {
            let reader = ReaderMock()
            let writer = WriterMock()
            let interceptor = InterceptorImpl()
            let worker = Worker(reader: reader, writer: writer, interceptor: interceptor)
            var writes: [Data] = []
            var formatterCalls = 0
            writer.writeContentClosure = { writes.append($0) }
            interceptor.save {
                formatterCalls += 1
                writer.write(content: Data("formatted diagnostic\n".utf8))
                DispatchQueue.main.async {
                    XCTAssertEqual(formatterCalls, 1)
                    XCTAssertEqual(writes, [Data("formatted diagnostic\n".utf8)])
                    assertPassthrough(interceptor)
                    let unrelatedOutput = Data("unrelated stderr output\n".utf8)
                    reader.readReturnValue = unrelatedOutput
                    worker.processOutput()
                    XCTAssertEqual(reader.readCallsCount, 4)
                    XCTAssertEqual(writes, [Data("formatted diagnostic\n".utf8), unrelatedOutput])
                    finished.fulfill()
                }
            }

            for fragment in ["warning header", "constraint details", "warning footer"] {
                reader.readReturnValue = Data(fragment.utf8)
                worker.processOutput()
            }
            XCTAssertEqual(reader.readCallsCount, 3)
            XCTAssertEqual(formatterCalls, 0)
            XCTAssertTrue(writes.isEmpty)
        }
        wait(for: [finished], timeout: 10)
    }

    func testWarningsQueuedDuringFormattingCompleteInFIFOOrderWithoutExtraReads() {
        let finished = expectation(description: "Complete warnings queued during active formatting without extra stderr reads")
        DispatchQueue.main.async {
            let reader = ReaderMock()
            let writer = WriterMock()
            let interceptor = InterceptorImpl()
            let worker = Worker(reader: reader, writer: writer, interceptor: interceptor)
            var formatted: [String] = []
            var writes: [Data] = []
            writer.writeContentClosure = { writes.append($0) }
            reader.readReturnValue = Data("first warning".utf8)
            interceptor.save {
                formatted.append("first")
                writer.write(content: Data("first diagnostic\n".utf8))
                interceptor.save {
                    formatted.append("second")
                    writer.write(content: Data("second diagnostic\n".utf8))
                }
                interceptor.save {
                    formatted.append("third")
                    writer.write(content: Data("third diagnostic\n".utf8))
                    DispatchQueue.main.async {
                        XCTAssertEqual(formatted, ["first", "second", "third"])
                        XCTAssertEqual(reader.readCallsCount, 2)
                        XCTAssertEqual(writes, [Data("first diagnostic\n".utf8), Data("second diagnostic\n".utf8), Data("third diagnostic\n".utf8)])
                        assertPassthrough(interceptor)
                        let unrelatedOutput = Data("unrelated stderr output\n".utf8)
                        reader.readReturnValue = unrelatedOutput
                        worker.processOutput()
                        XCTAssertEqual(reader.readCallsCount, 3)
                        XCTAssertEqual(writes.last, unrelatedOutput)
                        finished.fulfill()
                    }
                }
                reader.readReturnValue = Data("two additional warnings".utf8)
                worker.processOutput()
                XCTAssertEqual(reader.readCallsCount, 2)
                XCTAssertEqual(writes, [Data("first diagnostic\n".utf8)])
            }
            worker.processOutput()
            XCTAssertEqual(reader.readCallsCount, 1)
            XCTAssertTrue(writes.isEmpty)
        }
        wait(for: [finished], timeout: 10)
    }

    func testConcurrentCaptureAndDrainPreserveEveryDiagnosticOnce() {
        let producerCount = 4
        let consumerCount = 3
        let capture = ConcurrentDiagnostics(producerCount: producerCount, consumerCount: consumerCount)
        for _ in 0..<consumerCount {
            capture.completion.enter()
            Thread(target: capture, selector: #selector(ConcurrentDiagnostics.consume(_:)), object: nil).start()
        }
        for producer in 0..<producerCount {
            capture.completion.enter()
            Thread(target: capture, selector: #selector(ConcurrentDiagnostics.produce(_:)), object: NSNumber(value: producer)).start()
        }
        let result = capture.completion.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success)
        guard result == .success else { return }
        let expected = Set((0..<producerCount).flatMap { producer in
            (0..<capture.diagnosticsPerProducer).map { "\(producer):\($0)" }
        })
        XCTAssertEqual(capture.contents.count, expected.count)
        XCTAssertEqual(Set(capture.contents), expected)
        assertPassthrough(capture.interceptor)
    }

    func testCapturedWarningRetainsLayoutGuideUntilDeferredFormattingCompletes() {
        let finished = expectation(description: "Retain a layout guide until deferred diagnostic output completes")
        var restore: (() -> Void)?
        DispatchQueue.main.async {
            let reader = ReaderMock()
            reader.readReturnValue = Data("Auto Layout warning".utf8)
            let writer = WriterMock()
            var output = Data()
            writer.writeContentClosure = { output.append($0) }
            let interceptor = InterceptorImpl()
            let worker = Worker(reader: reader, writer: writer, interceptor: interceptor)
            let formatter = LayoutGuideFormatter()
            let previousWorker = shared
            let previousFormatter = defaultFormatter
            shared = worker
            defaultFormatter = formatter
            ViewType.swizzle()
            var hasRestored = false
            let cleanup = {
                guard !hasRestored else { return }
                hasRestored = true
                ViewType.swizzle()
                defaultFormatter = previousFormatter
                shared = previousWorker
            }
            restore = cleanup

            let view = ViewType(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
            weak var retainedGuide: LayoutGuideType?
            autoreleasepool {
                let guide = LayoutGuideType()
                retainedGuide = guide
                formatter.guide = guide
                view.addLayoutGuide(guide)
                let constraints = [
                    guide.widthAnchor.constraint(equalToConstant: 100),
                    guide.widthAnchor.constraint(equalToConstant: 10),
                ]
                NSLayoutConstraint.activate(constraints)
                view.callLayout()
                NSLayoutConstraint.deactivate(constraints)
                view.removeLayoutGuide(guide)
            }

            XCTAssertNotNil(retainedGuide)
            XCTAssertTrue(formatter.contents.isEmpty, "Formatting must not run inside the Auto Layout warning callback.")
            XCTAssertTrue(output.isEmpty)
            guard retainedGuide != nil, formatter.contents.isEmpty else {
                cleanup()
                restore = nil
                finished.fulfill()
                return
            }
            interceptor.save {
                DispatchQueue.main.async {
                    defer {
                        cleanup()
                        restore = nil
                        finished.fulfill()
                    }
                    XCTAssertEqual(reader.readCallsCount, 1)
                    XCTAssertFalse(formatter.contents.isEmpty)
                    XCTAssertEqual(output, Data(formatter.contents.joined().utf8))
                    XCTAssertEqual(formatter.callsAfterRelease, 0)
                    XCTAssertNil(retainedGuide)
                    assertPassthrough(interceptor)
                }
            }
            worker.processOutput()
            XCTAssertTrue(formatter.contents.isEmpty, "Formatting must remain deferred until the main queue runs the diagnostic.")
        }
        wait(for: [finished], timeout: 10)
        if let cleanup = restore {
            let restored = expectation(description: "Restore diagnostic globals after a failed asynchronous test")
            DispatchQueue.main.async {
                cleanup()
                restored.fulfill()
            }
            wait(for: [restored], timeout: 10)
        }
    }

    func testContextRetainsBothItemsOfConstraintOutsideExclusiveConstraints() {
        let finished = expectation(description: "Retain both constraint items for a custom formatter")
        DispatchQueue.main.async {
            defer { finished.fulfill() }
            let view = ViewType()
            var context: Context?
            weak var firstGuide: LayoutGuideType?
            weak var secondGuide: LayoutGuideType?
            autoreleasepool {
                let first = LayoutGuideType()
                let second = LayoutGuideType()
                firstGuide = first
                secondGuide = second
                view.addLayoutGuide(first)
                view.addLayoutGuide(second)
                let constraint = first.widthAnchor.constraint(equalTo: second.widthAnchor)
                context = Context(view: view, constraint: constraint, exclusiveConstraints: [])
                view.removeLayoutGuide(first)
                view.removeLayoutGuide(second)
            }
            XCTAssertNotNil(context)
            XCTAssertNotNil(firstGuide)
            XCTAssertNotNil(secondGuide)
            autoreleasepool { context = nil }
            XCTAssertNil(firstGuide)
            XCTAssertNil(secondGuide)
        }
        wait(for: [finished], timeout: 10)
    }
}

private final class LayoutGuideFormatter: Gedatsu.Formatter {
    weak var guide: LayoutGuideType?
    var contents: [String] = []
    var callsAfterRelease = 0

    func format(context: Context) -> String {
        guard guide != nil else {
            callsAfterRelease += 1
            XCTFail("The formatter ran after its layout guide was released.")
            return "late diagnostic"
        }
        let content = HierarchyFormatter<ViewType>().format(context: context)
        contents.append(content + "\n")
        return content
    }
}

private final class ConcurrentDiagnostics: NSObject {
    let interceptor = InterceptorImpl()
    let completion = DispatchGroup()
    let diagnosticsPerProducer = 250
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private let consumerCount: Int
    private var remainingProducers: Int
    private var collected: [String] = []

    init(producerCount: Int, consumerCount: Int) {
        self.remainingProducers = producerCount
        self.consumerCount = consumerCount
        super.init()
    }

    @objc func produce(_ producer: NSNumber) {
        defer { completion.leave() }
        for diagnostic in 0..<diagnosticsPerProducer {
            let content = "\(producer.intValue):\(diagnostic)"
            interceptor.save { self.record(content) }
            available.signal()
        }
        lock.lock()
        remainingProducers -= 1
        let finished = remainingProducers == 0
        lock.unlock()
        if finished {
            for _ in 0..<consumerCount {
                available.signal()
            }
        }
    }

    @objc func consume(_ object: NSObject?) {
        defer { completion.leave() }
        while available.wait(timeout: .now() + 5) == .success {
            lock.lock()
            let finished = remainingProducers == 0
            lock.unlock()
            switch interceptor.prepareInterception() {
            case .schedule(let initial):
                var next: InterceptType? = initial
                while let closure = next {
                    closure()
                    next = interceptor.completeInterception()
                }
            case .pending, .passthrough:
                break
            }
            if finished { return }
        }
    }

    private func record(_ content: String) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(content)
    }

    var contents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

private func assertPassthrough(_ interceptor: Interceptor, file: StaticString = #file, line: UInt = #line) {
    switch interceptor.prepareInterception() {
    case .passthrough:
        break
    case .pending:
        XCTFail("Diagnostic processing is still active.", file: file, line: line)
    case .schedule:
        XCTFail("A diagnostic is still queued.", file: file, line: line)
    }
}
