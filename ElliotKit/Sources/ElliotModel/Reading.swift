import Foundation

/// Where a fact came from and when, travelling with the fact.
///
/// `command` is the exact invocation, so a reader can re-run it rather than take
/// Elliot's word for the answer — the contract `CheckResult.command` already
/// states one layer up.
public struct Provenance: Codable, Sendable, Hashable {
    public var command: String
    public var observedAt: Date

    public init(command: String, observedAt: Date) {
        self.command = command
        self.observedAt = observedAt
    }
}

/// Why a fact is missing. Never an empty value, never a `false`.
public enum Unmeasured: Codable, Sendable, Hashable, Error {
    case requestFailed(String)
    case rateLimited
    case notPermitted
    /// The git-trees API set `truncated`. A path absent from a truncated tree
    /// proves nothing. The Python probe pipes through `--jq .tree[].path`, which
    /// throws this flag away before anyone can read it, and then reports a false
    /// absence indistinguishable from a real one.
    case treeTruncated
    /// Measured, but too long ago to answer as of `now`.
    case stale(age: TimeInterval)
    case exemptionsUnreadable(String)
    case exemptionsMalformed(line: Int, detail: String)
    /// The repository listing itself was too old or unreadable. Distinct from
    /// the rest because it invalidates *scope*, not one axis.
    case universeStale(age: TimeInterval)
    case universeUnreadable(String)
    /// Read successfully, and not interpretable — a workflow whose `on:` block
    /// cannot be located, say. Distinct from `requestFailed` because the network
    /// did its job: the fix is a better reader or a corrected file, never a retry.
    case unreadableContent(String)
}

/// How old an observation may be and still answer a question.
public struct FreshnessPolicy: Sendable, Hashable {
    public var maxAge: TimeInterval
    public init(maxAge: TimeInterval) { self.maxAge = maxAge }
    public static let `default` = FreshnessPolicy(maxAge: 24 * 3600)
}

/// A fact, or the named reason there isn't one — and in both cases what was
/// attempted and when.
///
/// There is deliberately no `valueOrDefault`, no `?? []` convenience and no
/// `Bool` accessor. `(try? …) ?? []` is the one line that turns a rate limit
/// into "no files found", which reads as non-compliant on every axis at once.
public enum Reading<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case observed(Value, Provenance)
    case unavailable(Unmeasured, Provenance)

    public var provenance: Provenance {
        switch self {
        case .observed(_, let p), .unavailable(_, let p): p
        }
    }

    public func value(freshAt now: Date, policy: FreshnessPolicy) -> Result<Value, Unmeasured> {
        switch self {
        case .unavailable(let why, _):
            return .failure(why)
        case .observed(let v, let p):
            let age = now.timeIntervalSince(p.observedAt)
            return age > policy.maxAge ? .failure(.stale(age: age)) : .success(v)
        }
    }
}
