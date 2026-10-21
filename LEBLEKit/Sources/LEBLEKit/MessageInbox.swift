import Foundation

/// Bounded complete-message queue. Overflow is terminal; bytes are never silently dropped.
actor MessageInbox {
    private var messages: [Data] = []
    private var bytes = 0
    private let maxMessages: Int
    private let maxBytes: Int
    private var waiters: [(UUID, CheckedContinuation<Data, Error>)] = []
    private var failure: Error?
    init(maxMessages: Int, maxBytes: Int) {
        self.maxMessages = maxMessages; self.maxBytes = maxBytes
    }
    func push(_ data: Data) throws {
        if let failure { throw failure }
        guard data.count <= maxBytes else { throw LEBLEError.bufferOverflow }
        if !waiters.isEmpty { waiters.removeFirst().1.resume(returning: data); return }
        guard messages.count < maxMessages, data.count <= maxBytes - bytes else { throw LEBLEError.bufferOverflow }
        messages.append(data); bytes += data.count
    }
    func receive() async throws -> Data {
        try Task.checkCancellation()
        if let failure { throw failure }
        if !messages.isEmpty { let data = messages.removeFirst(); bytes -= data.count; return data }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    func finish(_ error: Error) {
        guard failure == nil else { return }
        failure = error; messages.removeAll(); bytes = 0
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.1.resume(throwing: error) }
    }
}
