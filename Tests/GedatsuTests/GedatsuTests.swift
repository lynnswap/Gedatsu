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
    func testSchedulesDiagnosticsInFIFOOrderAcrossReadsThenPassesThroughOtherOutput() {
        let finished = expectation(description: "Write queued diagnostics in FIFO order")
        DispatchQueue.main.async {
            let reader = ReaderMock()
            let writer = WriterMock()
            let interceptor = InterceptorImpl()
            let worker = Worker(reader: reader, writer: writer, interceptor: interceptor)
            var writes: [Data] = []
            writer.writeContentClosure = { writes.append($0) }
            reader.readReturnValue = Data("first Auto Layout warning".utf8)
            interceptor.save { writer.write(content: Data("first diagnostic\n".utf8)) }
            interceptor.save { writer.write(content: Data("second diagnostic\n".utf8)) }

            worker.processOutput()
            XCTAssertEqual(reader.readCallsCount, 1)
            XCTAssertTrue(writes.isEmpty)

            reader.readReturnValue = Data("second Auto Layout warning".utf8)
            worker.processOutput()
            XCTAssertEqual(reader.readCallsCount, 2)
            XCTAssertTrue(writes.isEmpty)

            DispatchQueue.main.async {
                XCTAssertEqual(writes, [Data("first diagnostic\n".utf8), Data("second diagnostic\n".utf8)])
                let unrelatedOutput = Data("unrelated stderr output\n".utf8)
                reader.readReturnValue = unrelatedOutput
                worker.processOutput()

                XCTAssertEqual(reader.readCallsCount, 3)
                XCTAssertEqual(writes, [Data("first diagnostic\n".utf8), Data("second diagnostic\n".utf8), unrelatedOutput])
                XCTAssertNil(interceptor.takeNext())
                finished.fulfill()
            }
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
        XCTAssertNil(capture.interceptor.takeNext())
    }

    func testCapturedWarningRetainsLayoutGuideUntilDeferredFormattingCompletes() {
        let finished = expectation(description: "Retain a layout guide until deferred diagnostic output completes")
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
            let restore = {
                ViewType.swizzle()
                defaultFormatter = previousFormatter
                shared = previousWorker
            }

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
                restore()
                finished.fulfill()
                return
            }
            worker.processOutput()
            XCTAssertTrue(formatter.contents.isEmpty, "Formatting must remain deferred until the main queue runs the diagnostic.")

            DispatchQueue.main.async {
                defer {
                    restore()
                    finished.fulfill()
                }
                XCTAssertEqual(reader.readCallsCount, 1)
                XCTAssertFalse(formatter.contents.isEmpty)
                XCTAssertEqual(output, Data(formatter.contents.joined().utf8))
                XCTAssertEqual(formatter.callsAfterRelease, 0)
                XCTAssertNil(retainedGuide)
                XCTAssertNil(interceptor.takeNext())
            }
        }
        wait(for: [finished], timeout: 10)
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
            if let next = interceptor.takeNext() {
                next()
            } else {
                lock.lock()
                let finished = remainingProducers == 0
                lock.unlock()
                if finished { return }
            }
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
