import Foundation

/// Repositories whose authored pull requests are left out of every metric.
/// Automation can open and merge pull requests under the viewer's account
/// (for example, review-ledger bookkeeping); counting those as shipped work
/// would swamp merges, new work, and merge time.
struct MetricRepositoryExclusions: Codable, Equatable, Sendable {
    static let storageKey = "metrics.excludedRepositories.v1"
    /// Applied until the user saves their own list. Review-loop rounds are
    /// recorded as instantly merged pull requests in this repository.
    static let defaultRepositories = ["Keeper-Dating/review-ledgers"]
    static let `default` = MetricRepositoryExclusions(repositories: defaultRepositories)
    /// GitHub rejects search queries longer than 256 characters.
    static let maximumSearchQueryLength = 256

    private(set) var repositories: [String]

    init(repositories: [String]) {
        var seen = Set<String>()
        self.repositories = repositories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.isValidRepository($0) && seen.insert($0.lowercased()).inserted }
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    static func isValidRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
    }

    func excludes(_ repository: String) -> Bool {
        repositories.contains { $0.caseInsensitiveCompare(repository) == .orderedSame }
    }

    func setting(_ repository: String, excluded: Bool) -> Self {
        let others = repositories.filter { $0.caseInsensitiveCompare(repository) != .orderedSame }
        return Self(repositories: excluded ? others + [repository] : others)
    }

    /// Appends `-repo:` qualifiers so excluded pull requests do not consume the
    /// search API's 1,000-result ceiling. Qualifiers that would push the query
    /// past GitHub's length limit are omitted; callers must still filter the
    /// results, which is the authoritative exclusion.
    func searchQuery(_ base: String) -> String {
        var query = base
        for repository in repositories {
            let qualified = "\(query) -repo:\(repository)"
            guard qualified.count <= Self.maximumSearchQueryLength else { break }
            query = qualified
        }
        return query
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let stored = defaults.stringArray(forKey: storageKey) else { return .default }
        return Self(repositories: stored)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(repositories, forKey: Self.storageKey)
    }
}

extension AppSnapshot {
    /// Drops excluded pull requests together with their timeline events and
    /// handoffs so every derived metric and reconciliation check sees one
    /// consistent source. Assignment and action-label state are not metrics
    /// and are left untouched.
    func excludingRepositories(_ exclusions: MetricRepositoryExclusions) -> AppSnapshot {
        let removed = Set(pullRequests.lazy.filter { exclusions.excludes($0.repository) }.map(\.id))
        guard !removed.isEmpty else { return self }
        var copy = self
        copy.pullRequests.removeAll { removed.contains($0.id) }
        copy.events.removeAll { removed.contains($0.pullRequestID) }
        copy.handoffs.removeAll { removed.contains($0.pullRequestID) }
        return copy
    }
}

struct MetricRepositoryChoice: Equatable, Identifiable, Sendable {
    let repository: String
    /// Authored pull requests currently tracked; nil while excluded or restoring.
    let pullRequestCount: Int?
    let isCounted: Bool

    var id: String { repository.lowercased() }
}
