import Foundation

/// Tells a USB link that keeps dropping (cable, port or hub trouble; seen with a Galaxy at
/// 5 Gbps, QUIRKS G8) from a phone that's settling after being plugged in or changing its USB
/// mode, which also make it re-enumerate.
public struct UsbLinkHistory {
    /// Gone and back within this long counts as one re-enumeration rather than an unplug.
    public static let bounceWindow: TimeInterval = 4
    /// Re-enumerations this soon after plugging in are the phone settling, not trouble.
    public static let settlingTime: TimeInterval = 15
    /// This many drops within `dropWindow` means the link is unstable; the warning clears once
    /// that long passes without another (`calmed()`). Three, not two: a Galaxy switched between
    /// charging and file transfer re-enumerates with the same interfaces, which looks like a
    /// drop, and twice in two minutes is ordinary use. The flaky link it's for dropped 5 times
    /// in 36 s (G8).
    public static let dropsToWarn = 3
    public static let dropWindow: TimeInterval = 120

    private var pluggedAt: Date?
    /// The last device seen before it went away.
    private var gone: (at: Date, device: UsbAndroidDevice)?
    private var drops: [Date] = []

    /// Dropped and came back by itself more than once lately.
    public private(set) var isUnstable = false
    public var recentDrops: Int { drops.count }

    public init() {}

    /// The phone's USB device changed from `old` to `new` (nil: not on USB). Returns whether
    /// that was the link dropping and coming back.
    public mutating func changed(from old: UsbAndroidDevice?, to new: UsbAndroidDevice?, at now: Date) -> Bool {
        guard old?.registryID != new?.registryID else { return false }
        if let old, new == nil { gone = (now, old) }
        guard let new else { return false }
        // Back within a few seconds, or replaced in one step: the link re-enumerated.
        let previous = old ?? gone.flatMap { now.timeIntervalSince($0.at) < Self.bounceWindow ? $0.device : nil }
        gone = nil
        guard let previous else {
            pluggedAt = now
            return false
        }
        // Not trouble: a phone re-enumerates while it settles after being plugged in, and
        // whenever its USB mode changes (charging, file transfer, debugging).
        let settling = pluggedAt.map { now.timeIntervalSince($0) < Self.settlingTime } ?? true
        let modeChanged = previous.productID != new.productID || previous.hasMTP != new.hasMTP || previous.hasADB != new.hasADB
        guard !settling, !modeChanged else { return false }
        drops = drops.filter { now.timeIntervalSince($0) < Self.dropWindow } + [now]
        if drops.count >= Self.dropsToWarn { isUnstable = true }
        return true
    }

    /// `dropWindow` passed without another drop.
    public mutating func calmed() {
        isUnstable = false
        drops = []
    }
}
