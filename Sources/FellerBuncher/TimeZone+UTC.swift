import Foundation

extension TimeZone {
    /// The zero-offset zone, equal to `TimeZone.gmt` (which needs iOS 16 /
    /// macOS 13). `NSTimeZone(forSecondsFromGMT:)` cannot fail, so this needs
    /// no unwrap or fallback on the iOS 15 / macOS 12 floor.
    @usableFromInline
    static let fellerBuncherUTC: TimeZone = NSTimeZone(forSecondsFromGMT: 0) as TimeZone
}
