import Foundation

/// 重连策略——返回 nil 表示停止重试
public protocol RetryPolicy: Sendable {
    /// 根据已尝试次数返回下次重连前的延时
    /// - Parameter afterAttempt: 已尝试次数（从 0 开始）
    /// - Returns: 下次延时间隔，返回 nil 表示不再重试
    func nextDelay(afterAttempt: Int) -> TimeInterval?
}

// MARK: - 固定间隔重试

public struct FixedRetryPolicy: RetryPolicy {
    /// 固定重试间隔（秒）
    public let interval: TimeInterval
    /// 最大重试次数
    public let maxAttempts: Int

    public init(interval: TimeInterval, maxAttempts: Int) {
        self.interval = interval
        self.maxAttempts = maxAttempts
    }

    public func nextDelay(afterAttempt: Int) -> TimeInterval? {
        afterAttempt < maxAttempts ? interval : nil
    }
}

// MARK: - 指数退避重试

public struct ExponentialRetryPolicy: RetryPolicy {
    /// 初始间隔（秒）
    public let initial: TimeInterval
    /// 最大间隔上限（秒）
    public let max: TimeInterval
    /// 退避倍数（默认 2.0，即每次翻倍）
    public let multiplier: Double
    /// 最大重试次数
    public let maxAttempts: Int

    public init(initial: TimeInterval = 1,
                max: TimeInterval = 60,
                multiplier: Double = 2.0,
                maxAttempts: Int = .max) {
        self.initial = initial
        self.max = max
        self.multiplier = multiplier
        self.maxAttempts = maxAttempts
    }

    public func nextDelay(afterAttempt: Int) -> TimeInterval? {
        guard afterAttempt < maxAttempts else { return nil }
        let delay = initial * pow(multiplier, Double(afterAttempt))
        return min(delay, max)
    }
}

// MARK: - 便捷工厂方法

extension RetryPolicy where Self == FixedRetryPolicy {
    /// 创建固定间隔重试策略
    public static func fixed(interval: TimeInterval, maxAttempts: Int) -> FixedRetryPolicy {
        FixedRetryPolicy(interval: interval, maxAttempts: maxAttempts)
    }

    /// 不重试
    public static func noRetry() -> FixedRetryPolicy {
        FixedRetryPolicy(interval: 0, maxAttempts: 0)
    }
}

extension RetryPolicy where Self == ExponentialRetryPolicy {
    /// 创建指数退避重试策略
    public static func exponential(
        initial: TimeInterval = 1,
        max: TimeInterval = 60,
        multiplier: Double = 2.0,
        maxAttempts: Int = .max
    ) -> ExponentialRetryPolicy {
        ExponentialRetryPolicy(
            initial: initial,
            max: max,
            multiplier: multiplier,
            maxAttempts: maxAttempts
        )
    }
}
