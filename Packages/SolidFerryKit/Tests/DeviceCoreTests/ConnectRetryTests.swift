import DeviceCore
import Foundation
import Testing

private struct Refused: Error {}
private let start = Date(timeIntervalSince1970: 1_000_000)

@Test func retriesBackOffToEveryThirtySeconds() {
    var retry = ConnectRetry()
    #expect(retry.allowsAttempt(at: start))
    let delays = (0..<6).map { _ in retry.failed(Refused(), waitForChange: false, now: start) }
    #expect(delays == [3, 6, 12, 24, 30, 30])
    #expect(retry.failures == 6)
}

@Test func aFailureHoldsTheNextAttemptUntilItsTime() {
    var retry = ConnectRetry()
    _ = retry.failed(Refused(), waitForChange: false, now: start)
    #expect(retry.retryAt == start.addingTimeInterval(3))
    #expect(!retry.allowsAttempt(at: start.addingTimeInterval(2.9)))
    #expect(retry.allowsAttempt(at: start.addingTimeInterval(3)))
    retry.open()
    #expect(retry.allowsAttempt(at: start) && retry.retryAt == nil)
    #expect(retry.lastError is Refused)  // still shown while the next attempt runs
}

@Test func someFailuresWaitForThePhoneToChange() {
    var retry = ConnectRetry()
    #expect(retry.failed(Refused(), waitForChange: true, now: start) == nil)
    #expect(retry.retryAt == nil) // nothing to count down to
    #expect(!retry.allowsAttempt(at: start.addingTimeInterval(86_400)))
    retry = ConnectRetry()        // the phone was replugged or changed mode
    #expect(retry.allowsAttempt(at: start) && retry.failures == 0 && retry.lastError == nil)
}
