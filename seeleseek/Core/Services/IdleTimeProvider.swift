import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Seconds since the last keyboard/mouse event. Wishlist away-mode uses this
/// so auto-download can wait until the Mac is idle.
protocol IdleTimeProviding: Sendable {
    var secondsSinceLastInput: TimeInterval { get }
}

#if os(macOS)
/// System idle time via `CGEventSource` (combined session, any event type).
struct CGEventIdleTimeProvider: IdleTimeProviding {
    var secondsSinceLastInput: TimeInterval {
        // `UInt32.max` is the documented "any event" sentinel used by
        // `CGEventSourceSecondsSinceLastEventType`.
        let anyEvent = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }
}
#endif

/// Test double with a fixed idle age.
struct FixedIdleTimeProvider: IdleTimeProviding {
    var secondsSinceLastInput: TimeInterval
}
