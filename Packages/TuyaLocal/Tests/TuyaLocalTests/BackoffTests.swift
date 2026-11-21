import Testing

@testable import TuyaLocal

@Suite("Backoff")
struct BackoffTests {
    @Test func doublesFromOneSecondAndCapsAtThirty() {
        var b = Backoff(base: .seconds(1), cap: .seconds(30), jitter: { 0 })
        let delays = (0..<8).map { _ in b.nextDelay() }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    }

    @Test func jitterStaysWithinTwentyPercent() {
        var low = Backoff(base: .seconds(1), cap: .seconds(30), jitter: { -1 })
        var high = Backoff(base: .seconds(1), cap: .seconds(30), jitter: { 1 })
        #expect(abs(low.nextDelay().timeInterval - 0.8) < 1e-9)
        #expect(abs(high.nextDelay().timeInterval - 1.2) < 1e-9)
    }

    @Test func neverExceedsCapEvenWithMaximumJitter() {
        var b = Backoff(base: .seconds(1), cap: .seconds(30), jitter: { 1 })
        for _ in 0..<200 { #expect(b.nextDelay() <= .seconds(30)) }
        var r = Backoff()  // real random jitter
        for _ in 0..<2000 { #expect(r.nextDelay() <= .seconds(30)) }
    }

    @Test func resetStartsOver() {
        var b = Backoff(base: .seconds(1), cap: .seconds(30), jitter: { 0 })
        _ = (0..<5).map { _ in b.nextDelay() }
        b.reset()
        #expect(b.nextDelay() == .seconds(1))
    }
}
