import Foundation

/// Timing for restoring and keeping a saved GitHub sign-in.
struct SessionTiming: Sendable {
    /// Waits between attempts to reach GitHub with the saved token. The last value repeats.
    var reconnectDelays: [Duration]
    /// How long GitHub must keep rejecting the saved token, with no accepted
    /// request in between, before Codepulse asks the user to sign in again.
    var rejectionGracePeriod: Duration
    /// How many rejections that streak needs, so two isolated blips separated
    /// by an offline stretch never add up to a confirmation.
    var rejectionsToConfirm: Int

    static let standard = SessionTiming(
        reconnectDelays: [.seconds(2), .seconds(4), .seconds(8), .seconds(15)],
        rejectionGracePeriod: .seconds(120),
        rejectionsToConfirm: 3
    )

    func reconnectDelay(afterAttempt attempt: Int) -> Duration {
        guard let last = reconnectDelays.last else { return .zero }
        return attempt < reconnectDelays.count ? reconnectDelays[attempt] : last
    }
}

/// One 401 is not proof that the sign-in is gone: Codepulse has seen GitHub
/// reject a single request a second after accepting the same token. A streak
/// confirms revocation only after enough rejections persist for the grace
/// period with nothing accepted in between. It uses a clock that pauses while
/// the Mac sleeps, so rejections on either side of a sleep stay close together.
struct AuthorizationRejectionStreak: Equatable {
    private(set) var startedAt: SuspendingClock.Instant?
    private(set) var count = 0

    /// Records a rejection and returns whether the token is now confirmed invalid.
    mutating func recordRejection(at now: SuspendingClock.Instant, timing: SessionTiming) -> Bool {
        let start = startedAt ?? now
        startedAt = start
        count += 1
        return count >= timing.rejectionsToConfirm && start.duration(to: now) >= timing.rejectionGracePeriod
    }

    /// Starts over, for example after GitHub accepts a request or the user signs in.
    mutating func reset() {
        startedAt = nil
        count = 0
    }
}

/// What restoring a saved sign-in does after a failed attempt.
enum SessionRestoreDisposition: Equatable {
    /// GitHub rejected the token; counts toward `AuthorizationRejectionStreak`.
    case rejected
    /// A condition that clears on its own: no network, locked Keychain, a GitHub
    /// outage or rate limit. Retry, no earlier than `notBefore` when given.
    case retry(notBefore: Date?)
    /// Retrying cannot help, so show the error with the sign-in screen. The
    /// token is kept; a failure here must never repeat a Keychain prompt.
    case stop

    static func resolve(_ error: Error) -> Self {
        if let keychainError = error as? KeychainTokenError {
            return keychainError.isTemporarilyUnavailable ? .retry(notBefore: nil) : .stop
        }
        if error is URLError { return .retry(notBefore: nil) }
        guard let apiError = error as? GitHubAPIError else { return .stop }
        switch apiError {
        case .unauthorized: return .rejected
        case let .rateLimited(resetAt): return .retry(notBefore: resetAt)
        case .invalidResponse: return .retry(notBefore: nil)
        case let .server(status, _) where status >= 500: return .retry(notBefore: nil)
        default: return .stop
        }
    }
}
