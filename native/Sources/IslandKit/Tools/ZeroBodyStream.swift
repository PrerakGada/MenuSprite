import Foundation

/// An upload body of `length` zero bytes that never exists in memory: a bound pair of streams whose
/// reading end goes to URLSession, while a private serial queue refills the small buffer between
/// them from one shared 64 KB block of zeros as space frees up. A 100 MB speed-test upload costs the
/// pair's buffer and nothing more.
///
/// The writing end holds this object alive until it finishes (all bytes written, the reader closed,
/// or `close()`); the owner calls `close()` when the upload ends so an abandoned body is released.
public final class ZeroBodyStream: @unchecked Sendable {
    public let input: InputStream
    private let output: OutputStream
    private let queue = DispatchQueue(label: "MenuSprite.ZeroBodyStream")
    // Touched only on `queue`.
    private var remaining: Int64
    private var closed = false

    private static let zeros = [UInt8](repeating: 0, count: 64 * 1024)

    public init(length: Int64, bufferSize: Int = 256 * 1024) {
        var reader: InputStream?
        var writer: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &reader, outputStream: &writer)
        guard let reader, let writer else { preconditionFailure("Bound streams could not be created") }
        input = reader
        output = writer
        remaining = max(0, length)
        var context = CFStreamClientContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<ZeroBodyStream>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<ZeroBodyStream>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let events = CFStreamEventType.canAcceptBytes.rawValue | CFStreamEventType.errorOccurred.rawValue
            | CFStreamEventType.endEncountered.rawValue
        CFWriteStreamSetClient(output, events, { _, event, info in
            guard let info else { return }
            let body = Unmanaged<ZeroBodyStream>.fromOpaque(info).takeUnretainedValue()
            withExtendedLifetime(body) { body.handle(event) }
        }, &context)
        CFWriteStreamSetDispatchQueue(output, queue)
        CFWriteStreamOpen(output)
    }

    /// Stops producing and releases the writing end. Safe to call more than once, from any thread.
    public func close() {
        queue.async { self.finish() }
    }

    private func handle(_ event: CFStreamEventType) {
        guard !closed else { return }
        if event.contains(.canAcceptBytes) { fill() } else { finish() }
    }

    private func fill() {
        while remaining > 0, CFWriteStreamCanAcceptBytes(output) {
            let count = Int(min(remaining, Int64(Self.zeros.count)))
            let written = Self.zeros.withUnsafeBufferPointer { CFWriteStreamWrite(output, $0.baseAddress, count) }
            guard written > 0 else { finish(); return }
            remaining -= Int64(written)
        }
        if remaining == 0 { finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        CFWriteStreamSetDispatchQueue(output, nil)
        CFWriteStreamClose(output)
        // Last: clearing the client releases the stream's hold on this object.
        CFWriteStreamSetClient(output, 0, nil, nil)
    }
}
