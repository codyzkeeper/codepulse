import Foundation
import Security
import XCTest
@testable import Codepulse

@MainActor
final class SessionRestoreTests: XCTestCase {
    private var tokenStore: KeychainTokenStore!
    private var model: AppModel?

    override func setUp() {
        super.setUp()
        tokenStore = KeychainTokenStore(
            service: "app.prthroughput.PRThroughputTests.\(UUID().uuidString)",
            account: "session-test"
        )
    }

    override func tearDown() {
        model?.cancelSignIn()
        model = nil
        try? tokenStore.delete()
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testRejectionStreakConfirmsOnlyAfterSustainedRepeatedRejectionWithoutAcceptance() {
        var streak = AuthorizationRejectionStreak()
        let start = SuspendingClock().now
        let timing = SessionTiming.standard

        XCTAssertFalse(streak.recordRejection(at: start, timing: timing))
        XCTAssertFalse(streak.recordRejection(at: start.advanced(by: .seconds(60)), timing: timing))
        XCTAssertFalse(streak.recordRejection(at: start.advanced(by: .seconds(119)), timing: timing))
        streak.reset()
        XCTAssertFalse(streak.recordRejection(at: start.advanced(by: .seconds(200)), timing: timing))
        XCTAssertFalse(
            streak.recordRejection(at: start.advanced(by: .seconds(900)), timing: timing),
            "Two rejections separated by an offline stretch must not confirm."
        )
        XCTAssertTrue(streak.recordRejection(at: start.advanced(by: .seconds(915)), timing: timing))
    }

    func testOnlyFailuresThatClearOnTheirOwnAreRetried() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SessionRestoreDisposition.resolve(GitHubAPIError.unauthorized), .rejected)
        XCTAssertEqual(SessionRestoreDisposition.resolve(URLError(.notConnectedToInternet)), .retry(notBefore: nil))
        XCTAssertEqual(SessionRestoreDisposition.resolve(URLError(.timedOut)), .retry(notBefore: nil))
        XCTAssertEqual(
            SessionRestoreDisposition.resolve(KeychainTokenError.unexpectedStatus(errSecInteractionNotAllowed)),
            .retry(notBefore: nil)
        )
        XCTAssertEqual(SessionRestoreDisposition.resolve(GitHubAPIError.rateLimited(resetAt: reset)), .retry(notBefore: reset))
        XCTAssertEqual(SessionRestoreDisposition.resolve(GitHubAPIError.server(status: 502, message: "")), .retry(notBefore: nil))
        // A denied Keychain prompt must not be re-shown every few seconds.
        XCTAssertEqual(SessionRestoreDisposition.resolve(KeychainTokenError.unexpectedStatus(errSecAuthFailed)), .stop)
        XCTAssertEqual(SessionRestoreDisposition.resolve(GitHubAPIError.server(status: 403, message: "SSO")), .stop)
        XCTAssertEqual(SessionRestoreDisposition.resolve(GitHubAPIError.graphQL(["bad"])), .stop)
    }

    func testReconnectDelaysBackOffAndThenHoldSteady() {
        let timing = SessionTiming.standard
        XCTAssertEqual(timing.reconnectDelay(afterAttempt: 0), .seconds(2))
        XCTAssertEqual(timing.reconnectDelay(afterAttempt: 1), .seconds(4))
        XCTAssertEqual(timing.reconnectDelay(afterAttempt: 2), .seconds(8))
        XCTAssertEqual(timing.reconnectDelay(afterAttempt: 3), .seconds(15))
        XCTAssertEqual(timing.reconnectDelay(afterAttempt: 50), .seconds(15))
    }

    func testRestoringASavedSignInShowsConnectionProgressInsteadOfSignIn() {
        XCTAssertEqual(
            MenuPresentationState.resolve(connectionState: .connecting, hasSnapshot: false),
            .connecting
        )
        XCTAssertEqual(
            StatusItemPresentation.resolve(transient: nil, connectionState: .connecting, hasVerifiedSnapshot: false),
            .syncing
        )
    }

    /// Regression for 2026-11-24: GitHub answered one sync request with 401 a
    /// second after the same token succeeded, and Codepulse deleted the token,
    /// so the next login opened on the sign-in screen.
    func testSingleRejectionDuringSyncKeepsTheSavedSignIn() async throws {
        try tokenStore.save("saved-token")
        let requests = RequestCounter()
        StubURLProtocol.handler = { @Sendable request in
            requests.next() == 1 ? Self.viewerResponse(request) : Self.response(request, status: 401)
        }
        let model = makeModel(timing: SessionTiming(
            reconnectDelays: [.zero], rejectionGracePeriod: .seconds(120), rejectionsToConfirm: 3
        ))

        await model.restoreSession()

        XCTAssertGreaterThan(requests.value, 1, "The first sync must have run and been rejected.")
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertNil(model.errorMessage, "A single tolerated rejection is not surfaced.")
        XCTAssertEqual(try tokenStore.load(), "saved-token")
    }

    /// After a restart the login item can launch before Wi-Fi reconnects.
    /// Codepulse must wait for the network rather than show the sign-in screen.
    func testStartupKeepsRetryingUntilTheNetworkComesBack() async throws {
        try tokenStore.save("saved-token")
        let requests = RequestCounter()
        // Each viewer call retries four times internally, so ten failures make
        // the restore loop itself retry twice before the network returns.
        StubURLProtocol.handler = { @Sendable request in
            if requests.next() <= 10 { throw URLError(.notConnectedToInternet) }
            return Self.viewerResponse(request)
        }
        let model = makeModel(timing: SessionTiming(
            reconnectDelays: [.zero], rejectionGracePeriod: .seconds(120), rejectionsToConfirm: 3
        ))

        await model.restoreSession()

        XCTAssertGreaterThan(requests.value, 10)
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertEqual(try tokenStore.load(), "saved-token")
    }

    func testSustainedRejectionAsksToSignInAgainWithoutDeletingTheToken() async throws {
        try tokenStore.save("saved-token")
        StubURLProtocol.handler = { @Sendable request in Self.response(request, status: 401) }
        let model = makeModel(timing: SessionTiming(
            reconnectDelays: [.zero], rejectionGracePeriod: .zero, rejectionsToConfirm: 3
        ))

        await model.restoreSession()

        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertEqual(model.errorMessage, AppModel.signInAgainMessage)
        XCTAssertEqual(try tokenStore.load(), "saved-token")
    }

    func testFailureThatRetryingCannotFixShowsSignInWithTheReasonAndKeepsTheToken() async throws {
        try tokenStore.save("saved-token")
        let requests = RequestCounter()
        StubURLProtocol.handler = { @Sendable request in
            _ = requests.next()
            return Self.response(request, status: 403)
        }
        let model = makeModel(timing: .standard)

        await model.restoreSession()

        XCTAssertEqual(requests.value, 1, "A permanent failure must not be retried.")
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try tokenStore.load(), "saved-token")
    }

    func testRestoreWithoutASavedSignInShowsSignIn() async throws {
        StubURLProtocol.handler = { @Sendable request in
            XCTFail("No request should be made without a saved token.")
            return Self.response(request, status: 500)
        }
        let model = makeModel(timing: .standard)

        await model.restoreSession()

        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertNil(model.errorMessage)
    }

    private func makeModel(timing: SessionTiming) -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(
            snapshotStore: try? SnapshotStore(inMemory: true),
            actionConfiguration: ActionNotificationConfiguration(
                schemaVersion: ActionNotificationConfiguration.schemaVersion,
                organization: "Keeper-Dating",
                rules: []
            ),
            metricExclusions: MetricRepositoryExclusions(repositories: []),
            tokenStore: tokenStore,
            makeAPI: { GitHubAPI(token: $0, session: session, retryBaseDelay: 0) },
            sessionTiming: timing
        )
        self.model = model
        return model
    }

    private nonisolated static func viewerResponse(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data(#"{"data":{"viewer":{"id":"viewer-id","login":"octocat"}}}"#.utf8))
    }

    private nonisolated static func response(_ request: URLRequest, status: Int) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, Data(#"{"message":"Bad credentials"}"#.utf8))
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
