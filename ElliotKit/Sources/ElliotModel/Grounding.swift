import Foundation

/// What the citations attached to a piece of work turned out to be worth.
///
/// Three cases and not a `Bool`, shaped like `PRSign` for the same reason: a
/// boolean answers `false` both to "nobody ever cited a file" and to "files were
/// cited and are not there", and those are opposite facts. The first is a
/// silence — nothing was checkable. The second is an admission — something was
/// checkable and did not check out.
public enum Grounding: Sendable, Hashable {
    /// Nobody ever cited a file.
    case notCited
    /// Every cited file was found.
    case grounded
    /// Files were cited and `count` of them are not there.
    case missing(count: Int)

    /// Stable identifier surfaced to MCP callers, like `PRSign.code`.
    ///
    /// Deliberately not the enum's own name: these travel over the wire, and a
    /// case renamed for readability must not silently change what an agent
    /// matches on.
    public var code: String {
        switch self {
        case .notCited: "not_cited"
        case .grounded: "grounded"
        case .missing: "files_missing"
        }
    }

    /// One sentence, for the panel's tooltip and the card's refusal note.
    ///
    /// Here rather than in a view for the usual reason: a sentence written in a
    /// SwiftUI body is a claim nothing can test.
    public var summary: String {
        switch self {
        case .notCited:
            "Nothing cited a file, so nothing here was checkable."
        case .grounded:
            "Every cited file was found in the repository."
        case .missing(let count):
            count == 1
                ? "One cited file is not there."
                : "\(count) cited files are not there."
        }
    }

    /// Resolved citations in, one answer out. `Evidence.exists` was settled
    /// once, at harvest, against the repository root — this reads that fact and
    /// never touches the file system itself.
    public static func of(evidence: [Evidence]) -> Grounding {
        guard !evidence.isEmpty else { return .notCited }
        let missing = evidence.count { !$0.exists }
        return missing == 0 ? .grounded : .missing(count: missing)
    }
}

public extension Grounding {
    /// What the citations are worth. Data, like the other two weights.
    var valueWeight: Double {
        switch self {
        // Unreachable from `CardValue.of`, which refuses an uncited card rather
        // than scoring it — the same trade `Effort.unstated` makes.
        case .notCited: 0.0
        // A story whose citations do not check out may still be right, but it
        // was not checkable, and an unattended queue is the last place to spend
        // an agent on that.
        case .missing: 0.3
        case .grounded: 1.0
        }
    }
}
