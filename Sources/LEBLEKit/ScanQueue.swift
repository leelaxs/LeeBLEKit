import Foundation
@preconcurrency import CoreBluetooth

/// 扫描队列——共享一次扫描会话，多任务排队
///
/// - 新任务加入时先检查缓存（之前的扫描结果），命中则立即返回
/// - 每个任务独立超时，不影响后加入的任务
/// - 所有任务匹配后提前结束扫描
final class ScanQueue: @unchecked Sendable {

    /// 单个扫描任务
    struct Task: Sendable {
        let id: UUID                     // 任务唯一标识
        let rule: ConnectionRule         // 匹配规则
        let timeout: TimeInterval        // 该任务的超时时间
        let continuation: CheckedContinuation<ScanResult, Error>  // 异步挂起点
    }

    private let lock = NSLock()
    private var tasks: [ScanQueue.Task] = []
    private(set) var discovered: [UUID: ScanResult] = [:]

    /// 是否有未完成的任务
    var hasPendingTasks: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !tasks.isEmpty
    }

    /// 添加任务到队列
    /// - Returns: true 表示需要启动/继续扫描，false 表示缓存命中已立即完成
    func add(_ task: Task) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // 先检查缓存：后续加入的任务可能匹配之前已发现的设备
        for (_, result) in discovered {
            if task.rule.matches(result) {
                lock.unlock()
                task.continuation.resume(returning: result)
                lock.lock()
                return false
            }
        }

        tasks.append(task)
        return true
    }

    /// 收到一条广播数据时调用——匹配所有未完成任务
    func checkAndResolve(_ result: ScanResult) {
        lock.lock()
        discovered[result.id] = result
        var resolved: [ScanQueue.Task] = []
        var remaining: [ScanQueue.Task] = []
        for task in tasks {
            if task.rule.matches(result) {
                resolved.append(task)
            } else {
                remaining.append(task)
            }
        }
        tasks = remaining
        lock.unlock()

        for task in resolved {
            task.continuation.resume(returning: result)
        }
    }

    /// Resolve only the specified request; later callbacks become no-ops.
    func remove(id: UUID, error: Error) {
        lock.lock()
        let task = tasks.first { $0.id == id }
        tasks.removeAll { $0.id == id }
        lock.unlock()
        task?.continuation.resume(throwing: error)
    }

    /// 全部取消（通常因蓝牙状态变化）
    func cancelAll() {
        lock.lock()
        let all = tasks
        tasks = []
        lock.unlock()
        for task in all {
            task.continuation.resume(throwing: LEBLEError.scanningNotReady)
        }
    }

    /// 清空发现缓存（不影响进行中的任务）
    func clearDiscovered() {
        lock.lock()
        discovered = [:]
        lock.unlock()
    }
}
