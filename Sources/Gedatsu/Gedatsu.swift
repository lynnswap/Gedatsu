import Foundation

internal class Worker {
    internal let reader: Reader
    internal let writer: Writer
    internal let interceptor: Interceptor
    internal init(reader: Reader, writer: Writer, interceptor: Interceptor) {
        self.reader = reader
        self.writer = writer
        self.interceptor = interceptor
    }
    
    private var source: DispatchSourceRead!
    internal func open() {
        _ = dup2(STDERR_FILENO, writer.writingFileDescriptor)
        _ = dup2(reader.writingFileDescriptor, STDERR_FILENO)
        source = DispatchSource.makeReadSource(fileDescriptor: reader.readingFileDescriptor, queue: .init(label: "com.bannzai.gedatsu"))
        source.setEventHandler {
            self.processOutput()
        }
        source.resume()
    }

    func processOutput() {
        // Drain stderr even when replacing its contents, so the read source can advance.
        let data = reader.read()
        switch interceptor.prepareInterception() {
        case .passthrough:
            writer.write(content: data)
        case .pending:
            break
        case .schedule(let closure):
            schedule(closure)
        }
    }

    private func schedule(_ closure: @escaping InterceptType) {
        DispatchQueue.main.async {
            closure()
            if let next = self.interceptor.completeInterception() {
                self.schedule(next)
            }
        }
    }
}

extension Worker: TextOutputStream {
    func write(_ string: String) {
        let data = string.data(using: .utf8)
        gedatsuAssert(data != nil)
        data.map(writer.write(content:))
    }
}

internal var shared: Worker?

public func open() {
    if shared != nil {
        return
    }
    shared = Worker(
        reader: ReaderImpl(),
        writer: WriterImpl(),
        interceptor: InterceptorImpl()
    )
    ViewType.swizzle()
    shared?.open()
}
