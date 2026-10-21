import Foundation
@preconcurrency import CoreBluetooth

/// Resolves once, including cancellation that arrives before registration.
final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

func timeoutNanoseconds(_ seconds: TimeInterval) throws -> UInt64 {
    guard seconds.isFinite, seconds >= 0,
          seconds < Double(UInt64.max) / 1_000_000_000 else {
        throw LEBLEError.invalidData
    }
    return UInt64(seconds * 1_000_000_000)
}

/// Independent subscriptions: observing state never replaces readiness waiters.
final class StateBroadcast<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    private var listeners: [UUID: AsyncStream<Value>.Continuation] = [:]
    init(_ value: Value) { self.value = value }

    func stream() -> AsyncStream<Value> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            listeners[id] = continuation
            continuation.yield(value)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    func update(_ value: Value) {
        lock.lock()
        self.value = value
        for listener in listeners.values { listener.yield(value) }
        lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock(); listeners[id] = nil; lock.unlock()
    }
}

final class Readiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var waiters: [UUID: OneShot<Void>] = [:]

    func update(_ state: CBManagerState) {
        lock.lock()
        ready = state == .poweredOn
        let pending = ready ? Array(waiters.values) : []
        if ready { waiters.removeAll() }
        lock.unlock()
        pending.forEach { $0.resolve(.success(())) }
    }

    private func add(_ waiter: OneShot<Void>, id: UUID) {
        lock.lock()
        if ready {
            lock.unlock()
            waiter.resolve(.success(()))
        } else {
            waiters[id] = waiter
            lock.unlock()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock(); waiters[id] = nil; lock.unlock()
    }

    func wait(timeout: TimeInterval) async throws {
        let nanos = try timeoutNanoseconds(timeout)
        let id = UUID()
        let waiter = OneShot<Void>()
        add(waiter, id: id)
        let timer = Task {
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            waiter.resolve(.failure(LEBLEError.scanningNotReady))
        }
        defer { timer.cancel(); remove(id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter.install($0) }
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
        }
    }
}
