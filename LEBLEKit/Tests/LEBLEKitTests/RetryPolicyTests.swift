import XCTest
@testable import LEBLEKit

final class RetryPolicyTests: XCTestCase {

    // MARK: - Fixed

    func test_fixed_returnsInterval() {
        let policy = FixedRetryPolicy(interval: 3, maxAttempts: 5)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 0), 3)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 1), 3)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 4), 3)
    }

    func test_fixed_exceedsMaxAttempts() {
        let policy = FixedRetryPolicy(interval: 3, maxAttempts: 3)
        XCTAssertNil(policy.nextDelay(afterAttempt: 3))
        XCTAssertNil(policy.nextDelay(afterAttempt: 10))
    }

    func test_fixed_noRetry() {
        let policy = FixedRetryPolicy.noRetry()
        XCTAssertNil(policy.nextDelay(afterAttempt: 0))
        XCTAssertNil(policy.nextDelay(afterAttempt: 1))
    }

    // MARK: - Exponential

    func test_exponential_grows() {
        let policy = ExponentialRetryPolicy(initial: 1, max: 60, multiplier: 2, maxAttempts: 5)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 0), 1)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 1), 2)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 2), 4)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 3), 8)
    }

    func test_exponential_cappedAtMax() {
        let policy = ExponentialRetryPolicy(initial: 1, max: 5, multiplier: 2, maxAttempts: 10)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 0), 1)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 1), 2)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 2), 4)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 3), 5) // capped
        XCTAssertEqual(policy.nextDelay(afterAttempt: 4), 5)
    }

    func test_exponential_exceedsMaxAttempts() {
        let policy = ExponentialRetryPolicy(initial: 1, max: 60, multiplier: 2, maxAttempts: 2)
        XCTAssertNotNil(policy.nextDelay(afterAttempt: 0))
        XCTAssertNotNil(policy.nextDelay(afterAttempt: 1))
        XCTAssertNil(policy.nextDelay(afterAttempt: 2))
    }

    // MARK: - Convenience

    func test_convenience_fixed() {
        let policy: FixedRetryPolicy = .fixed(interval: 2, maxAttempts: 3)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 0), 2)
    }

    func test_convenience_exponential() {
        let policy: ExponentialRetryPolicy = .exponential(initial: 1, max: 30)
        XCTAssertEqual(policy.nextDelay(afterAttempt: 0), 1)
    }
}
