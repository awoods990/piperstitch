// The licensing client is a desktop-app concern (see LICENSING.md). The
// Linux server build (see server/) has no use for it, and CryptoKit /
// URLSession differ there, so the whole file compiles only on Apple
// platforms. The code below is unchanged.
#if canImport(CryptoKit)
import Foundation

/// Where this Mac stands, decided purely from local facts (trial start,
/// stored entitlement, the clock) — no network. `LicenseManager` in the
/// app target owns the network side and feeds the results in here.
public enum LicenseStatus: Equatable, Sendable {
    /// No account, within the free trial. `daysRemaining` counts today.
    case trial(daysRemaining: Int)
    /// Trial over and not signed in — the editor is locked.
    case trialExpired
    /// Signed in with a currently-valid entitlement.
    case subscribed(Entitlement)
    /// Signed in, but the last entitlement we hold has expired and the
    /// service hasn't given us a new one (subscription ended, or the Mac
    /// has been offline past the token's life). Locked.
    case subscriptionLapsed(Entitlement)

    public var isLocked: Bool {
        switch self {
        case .trial, .subscribed: return false
        case .trialExpired, .subscriptionLapsed: return true
        }
    }

    public var isSignedIn: Bool {
        switch self {
        case .subscribed, .subscriptionLapsed: return true
        case .trial, .trialExpired: return false
        }
    }
}

public enum LicenseEvaluator {
    /// The trial runs `trialDays` calendar days counting the first-launch
    /// day as day one, so a 14-day trial started at 11pm still ends at the
    /// end of the 14th day, not 14×24h later.
    public static func trialDaysRemaining(firstLaunch: Date, trialDays: Int, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: firstLaunch)
        let today = calendar.startOfDay(for: now)
        let elapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(0, trialDays - elapsed)
    }

    public static func evaluate(entitlement: Entitlement?, firstLaunch: Date?, trialDays: Int, now: Date = Date()) -> LicenseStatus {
        if let e = entitlement {
            return e.isValid(at: now) ? .subscribed(e) : .subscriptionLapsed(e)
        }
        // No first-launch date recorded yet means this IS the first launch.
        let start = firstLaunch ?? now
        let remaining = trialDaysRemaining(firstLaunch: start, trialDays: trialDays, now: now)
        return remaining > 0 ? .trial(daysRemaining: remaining) : .trialExpired
    }
}
#endif
