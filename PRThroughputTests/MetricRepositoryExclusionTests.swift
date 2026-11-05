import XCTest
@testable import Codepulse

final class MetricRepositoryExclusionTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testDefaultsToReviewLedgersUntilTheUserSavesAList() throws {
        let suiteName = "MetricRepositoryExclusionTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MetricRepositoryExclusions.load(defaults: suite).repositories, ["Keeper-Dating/review-ledgers"])

        MetricRepositoryExclusions(repositories: []).save(defaults: suite)
        XCTAssertEqual(MetricRepositoryExclusions.load(defaults: suite).repositories, [], "An emptied list must stay empty")

        MetricRepositoryExclusions(repositories: ["o/b", "o/a"]).save(defaults: suite)
        XCTAssertEqual(MetricRepositoryExclusions.load(defaults: suite).repositories, ["o/a", "o/b"])
    }

    func testNormalizesDeduplicatesAndRejectsMalformedRepositories() {
        let exclusions = MetricRepositoryExclusions(repositories: [
            " Keeper-Dating/review-ledgers ", "keeper-dating/REVIEW-LEDGERS", "not a repo", "o/r -repo:x", "", "o/r",
        ])
        XCTAssertEqual(exclusions.repositories, ["Keeper-Dating/review-ledgers", "o/r"])
        XCTAssertTrue(exclusions.excludes("keeper-dating/review-ledgers"))
        XCTAssertFalse(exclusions.excludes("Keeper-Dating/matchmaking"))
    }

    func testTogglingARepositoryIsCaseInsensitive() {
        let exclusions = MetricRepositoryExclusions.default
        XCTAssertEqual(exclusions.setting("keeper-dating/review-ledgers", excluded: false).repositories, [])
        XCTAssertEqual(
            exclusions.setting("o/r", excluded: true).repositories,
            ["Keeper-Dating/review-ledgers", "o/r"]
        )
        XCTAssertEqual(exclusions.setting("Keeper-Dating/review-ledgers", excluded: true), exclusions)
    }

    func testSearchQualifiersNeverExceedGitHubQueryLimit() {
        let base = "is:pr author:me created:2026-10-06T00:00:00Z..2026-11-05T00:00:00Z"
        XCTAssertEqual(
            MetricRepositoryExclusions.default.searchQuery(base),
            base + " -repo:Keeper-Dating/review-ledgers"
        )
        let many = MetricRepositoryExclusions(repositories: (0..<20).map { "owner/repository-number-\($0)" })
        let query = many.searchQuery(base)
        XCTAssertLessThanOrEqual(query.count, MetricRepositoryExclusions.maximumSearchQueryLength)
        XCTAssertTrue(query.hasPrefix(base))
    }

    func testExcludingRepositoriesDropsPullRequestsEventsAndHandoffsButKeepsAssignment() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)
        let work = Self.pull(id: "work", repository: "Keeper-Dating/matchmaking", viewer: viewer, now: now)
        let ledger = Self.pull(id: "ledger", repository: "Keeper-Dating/review-ledgers", viewer: viewer, now: now)
        let snapshot = AppSnapshot(
            viewer: viewer,
            pullRequests: [work, ledger],
            events: [
                TimelineEvent(id: "work-merged", pullRequestID: "work", kind: .merged, at: now),
                TimelineEvent(id: "ledger-merged", pullRequestID: "ledger", kind: .merged, at: now),
                TimelineEvent(id: "ledger-review", pullRequestID: "ledger", kind: .reviewRequested(reviewer), at: now),
            ],
            handoffs: [Handoff(id: "h", pullRequestID: "ledger", reviewerID: reviewer.id, at: now, outcome: .pending)],
            assignedPullRequestIDs: ["ledger"],
            attentionItems: [],
            metadata: SyncMetadata.empty
        )

        let filtered = snapshot.excludingRepositories(.default)

        XCTAssertEqual(filtered.pullRequests.map(\.id), ["work"])
        XCTAssertEqual(filtered.events.map(\.id), ["work-merged"])
        XCTAssertTrue(filtered.handoffs.isEmpty)
        XCTAssertEqual(filtered.assignedPullRequestIDs, ["ledger"])
        XCTAssertEqual(filtered.windowMetrics(range: .days7, asOf: now).merged, 1)
        XCTAssertEqual(snapshot.excludingRepositories(MetricRepositoryExclusions(repositories: [])).pullRequests.count, 2)
    }

    func testFullRefreshNeverFetchesOrCountsExcludedRepositories() async throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let created = formatter.string(from: now.addingTimeInterval(-7_200))
        let merged = formatter.string(from: now.addingTimeInterval(-3_600))
        func node(_ id: String, _ repository: String, number: Int) -> String {
            #"{"__typename":"PullRequest","id":"\#(id)","number":\#(number),"title":"\#(id)","url":"https://github.com/\#(repository)/pull/\#(number)","createdAt":"\#(created)","updatedAt":"\#(merged)","isDraft":false,"state":"MERGED","mergedAt":"\#(merged)","closedAt":"\#(merged)","author":{"__typename":"User","login":"me","id":"viewer"},"repository":{"nameWithOwner":"\#(repository)"}}"#
        }
        let nodes = [
            node("work", "Keeper-Dating/matchmaking", number: 1),
            // GitHub's search can still return an excluded repository when its
            // qualifier is dropped for length, so the result filter must hold.
            node("ledger", "keeper-dating/review-ledgers", number: 2),
        ].joined(separator: ",")
        nonisolated(unsafe) var searchQueries: [String] = []
        nonisolated(unsafe) var timelineIDs: [String] = []
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            let variables = object["variables"] as? [String: Any] ?? [:]
            let payload: String
            if query.contains("query Viewer {") {
                payload = #"{"data":{"viewer":{"id":"viewer","login":"me"}}}"#
            } else if query.contains("SearchPullRequests") {
                let search = try XCTUnwrap(variables["query"] as? String)
                searchQueries.append(search)
                payload = search.contains("author:me")
                    ? #"{"data":{"search":{"issueCount":2,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(nodes)]}}}"#
                    : #"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#
            } else if query.contains("ViewerOpenPullRequests") {
                payload = #"{"data":{"viewer":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#
            } else {
                XCTAssertTrue(query.contains("PullRequestTimeline"))
                timelineIDs.append(try XCTUnwrap(variables["id"] as? String))
                payload = #"{"data":{"node":{"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"MergedEvent","id":"merged-event","createdAt":"\#(merged)"}]}}}}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let coordinator = SyncCoordinator(api: GitHubAPI(token: "test", session: URLSession(configuration: configuration)))

        let result = try await coordinator.refresh(
            previous: nil,
            configuration: .blank,
            exclusions: .default
        )

        XCTAssertEqual(result.snapshot.pullRequests.map(\.id), ["work"])
        XCTAssertEqual(timelineIDs, ["work"], "Excluded pull requests must not spend timeline queries")
        let authoredQueries = searchQueries.filter { $0.contains("author:me") }
        XCTAssertEqual(authoredQueries.count, 2)
        XCTAssertTrue(authoredQueries.allSatisfy { $0.hasSuffix(" -repo:Keeper-Dating/review-ledgers") })
        XCTAssertEqual(result.snapshot.windowMetrics(range: .days7, asOf: now).merged, 1)
    }

    private static func pull(id: String, repository: String, viewer: GitHubUser, now: Date) -> PullRequestSnapshot {
        PullRequestSnapshot(
            id: id, repository: repository, number: 1, title: id,
            url: URL(string: "https://github.com/\(repository)/pull/1")!, authorID: viewer.id,
            eligibleAt: now.addingTimeInterval(-3_600), updatedAt: now,
            isDraft: false, state: .merged, mergedAt: now, closedAt: now
        )
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
