import Foundation

/// A repository's own excuse for one axis, filed as `.elliot/standards.yml` and
/// reviewable in a pull request the way the code it excuses is.
public struct Exemption: Codable, Sendable, Hashable {
    public var standard: Standard
    public var reason: String
    public var grantedBy: String
    public var grantedAt: Date
    public var expires: Date?
    public var evidence: String?

    public init(
        standard: Standard,
        reason: String,
        grantedBy: String,
        grantedAt: Date,
        expires: Date? = nil,
        evidence: String? = nil
    ) {
        self.standard = standard
        self.reason = reason
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
        self.expires = expires
        self.evidence = evidence
    }

    /// Permanent when there is no `expires` date; otherwise a decision, not a
    /// permanent hole — inactive from the moment `now` reaches it.
    public func isActive(at now: Date) -> Bool {
        guard let expires else { return true }
        return now < expires
    }
}

/// The parsed contents of `.elliot/standards.yml`.
public struct StandardsFile: Codable, Sendable, Hashable {
    public var version: Int
    public var repo: String?
    public var exemptions: [Exemption]

    public init(version: Int, repo: String? = nil, exemptions: [Exemption] = []) {
        self.version = version
        self.repo = repo
        self.exemptions = exemptions
    }

    public static let empty = StandardsFile(version: 1, repo: nil, exemptions: [])
}

/// Total, strict, dependency-free — the `IssueMarkdownParser` contract.
///
/// It refuses what it does not understand instead of skipping it. The failure
/// mode of a lenient parser here is an unattended `claude -p` in a repository
/// someone deliberately excused, so leniency is the expensive direction.
///
/// The supported subset is deliberately tiny: `key: value`, a `-` list of
/// mappings under `exemptions:`, `>` folded scalars, `#` comments, two-space
/// indentation. Anything else is a refusal naming its line.
public enum StandardsFileParser {

    /// Every path returns either a complete file or a located refusal — never
    /// a partially-read one. `nameWithOwner` is what the caller believes this
    /// repository to be; a `repo:` key that disagrees refuses rather than
    /// silencing an axis in the wrong place.
    public static func parse(
        _ text: String, expecting nameWithOwner: String?
    ) -> Result<StandardsFile, Unmeasured> {
        let lines = Self.numberedLines(of: text)
        var version: Int?
        var repo: String?
        var exemptions: [Exemption] = []
        var pos = 0

        while pos < lines.count {
            switch Self.step(lines, pos) {
            case .failure(let error):
                return .failure(error)

            case .success(.skip):
                pos += 1

            case .success(.line(let indent, let content)):
                guard indent == 0 else {
                    return .failure(
                        .exemptionsMalformed(line: lines[pos].number, detail: "unexpected indentation"))
                }
                guard let (key, value) = Self.splitKeyValue(content) else {
                    return .failure(
                        .exemptionsMalformed(
                            line: lines[pos].number, detail: "expected 'key: value', found '\(content)'"))
                }

                switch key {
                case "version":
                    guard Self.unquote(value) == "1" else {
                        return .failure(
                            .exemptionsMalformed(
                                line: lines[pos].number, detail: "unsupported version '\(value)'"))
                    }
                    version = 1
                    pos += 1

                case "repo":
                    let declared = Self.unquote(value)
                    if let nameWithOwner, declared != nameWithOwner {
                        return .failure(
                            .exemptionsMalformed(
                                line: lines[pos].number,
                                detail: "repo declares \(declared) but Elliot expected \(nameWithOwner)"))
                    }
                    repo = declared
                    pos += 1

                case "exemptions":
                    if value.isEmpty {
                        switch Self.parseExemptionsList(lines, from: pos + 1, parentIndent: 0) {
                        case .failure(let error): return .failure(error)
                        case .success(let (list, next)):
                            exemptions = list
                            pos = next
                        }
                    } else if value == "[]" {
                        exemptions = []
                        pos += 1
                    } else {
                        return .failure(
                            .exemptionsMalformed(
                                line: lines[pos].number, detail: "unsupported 'exemptions' value '\(value)'"))
                    }

                default:
                    return .failure(
                        .exemptionsMalformed(line: lines[pos].number, detail: "unknown key '\(key)'"))
                }
            }
        }

        guard let version else {
            return .failure(.exemptionsMalformed(line: max(lines.count, 1), detail: "missing 'version'"))
        }
        return .success(StandardsFile(version: version, repo: repo, exemptions: exemptions))
    }

    // MARK: - The exemptions list

    private static let exemptionKeys: Set<String> = [
        "standard", "reason", "granted_by", "granted_at", "expires", "evidence",
    ]

    /// A run of `-` mappings at `parentIndent + 2`, the "two-space indentation"
    /// half of the supported subset. Stops — without consuming the line — the
    /// moment it sees anything at `parentIndent` or shallower, since that is
    /// the next top-level key, not part of this list. Anything indented
    /// in between refuses rather than being read as "the list must be over":
    /// a mis-indented item is exactly the silently-dropped exemption this
    /// parser exists to prevent.
    private static func parseExemptionsList(
        _ lines: [Line], from start: Int, parentIndent: Int
    ) -> Result<(items: [Exemption], next: Int), Unmeasured> {
        let itemIndent = parentIndent + 2
        var items: [Exemption] = []
        var pos = start

        while pos < lines.count {
            switch Self.step(lines, pos) {
            case .failure(let error):
                return .failure(error)

            case .success(.skip):
                pos += 1

            case .success(.line(let indent, let text)):
                if indent <= parentIndent {
                    return .success((items, pos))
                }
                guard indent == itemIndent, text.hasPrefix("- ") else {
                    return .failure(
                        .exemptionsMalformed(
                            line: lines[pos].number,
                            detail: "expected a '-' item indented \(itemIndent) spaces under 'exemptions:'"))
                }
                let afterDash = String(text.dropFirst(2)).trimmed()
                guard !afterDash.isEmpty else {
                    return .failure(
                        .exemptionsMalformed(
                            line: lines[pos].number, detail: "a list item must be a mapping"))
                }
                switch Self.parseExemption(
                    lines, openPos: pos, afterDash: afterDash, itemIndent: itemIndent
                ) {
                case .failure(let error): return .failure(error)
                case .success(let (exemption, next)):
                    items.append(exemption)
                    pos = next
                }
            }
        }

        return .success((items, pos))
    }

    /// One `- standard: … / reason: … / …` mapping. `afterDash` is the first
    /// key, already split off the dash on `openPos`'s own line; every later
    /// key is an ordinary line at `itemIndent + 2`. Stops — again without
    /// consuming the line — at the first line that is not at that indent, and
    /// leaves the caller to decide what it is.
    private static func parseExemption(
        _ lines: [Line], openPos: Int, afterDash: String, itemIndent: Int
    ) -> Result<(exemption: Exemption, next: Int), Unmeasured> {
        let keyIndent = itemIndent + 2
        var fields: [String: (line: Int, value: String)] = [:]

        switch Self.recordKey(
            line: lines[openPos].number, text: afterDash, into: &fields,
            lines: lines, after: openPos + 1, keyIndent: keyIndent
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let afterFirst):
            var pos = afterFirst
            while pos < lines.count {
                switch Self.step(lines, pos) {
                case .failure(let error):
                    return .failure(error)
                case .success(.skip):
                    pos += 1
                case .success(.line(let indent, let content)):
                    guard indent == keyIndent else {
                        return Self.buildExemption(fields: fields, itemLine: lines[openPos].number, next: pos)
                    }
                    switch Self.recordKey(
                        line: lines[pos].number, text: content, into: &fields,
                        lines: lines, after: pos + 1, keyIndent: keyIndent
                    ) {
                    case .failure(let error): return .failure(error)
                    case .success(let next): pos = next
                    }
                }
            }
            return Self.buildExemption(fields: fields, itemLine: lines[openPos].number, next: pos)
        }
    }

    /// Records one `key: value` line into `fields` — consuming a folded
    /// scalar body first if this is `reason: >` — and returns the position to
    /// resume scanning from.
    private static func recordKey(
        line: Int, text: String,
        into fields: inout [String: (line: Int, value: String)],
        lines: [Line], after pos: Int, keyIndent: Int
    ) -> Result<Int, Unmeasured> {
        guard let (key, rawValue) = Self.splitKeyValue(text) else {
            return .failure(
                .exemptionsMalformed(line: line, detail: "expected 'key: value', found '\(text)'"))
        }
        guard Self.exemptionKeys.contains(key) else {
            return .failure(.exemptionsMalformed(line: line, detail: "unknown exemption key '\(key)'"))
        }
        guard fields[key] == nil else {
            return .failure(.exemptionsMalformed(line: line, detail: "duplicate key '\(key)'"))
        }
        if key == "reason", rawValue == ">" {
            switch Self.consumeFolded(lines, from: pos, deeperThan: keyIndent) {
            case .failure(let error): return .failure(error)
            case .success(let (folded, next)):
                fields["reason"] = (line, folded)
                return .success(next)
            }
        }
        fields[key] = (line, Self.unquote(rawValue))
        return .success(pos)
    }

    /// Validates the required keys and builds the `Exemption`. Every refusal
    /// here names the key it is missing and the line the *item* started on —
    /// there is no other line to point to for something that is not there.
    private static func buildExemption(
        fields: [String: (line: Int, value: String)], itemLine: Int, next: Int
    ) -> Result<(exemption: Exemption, next: Int), Unmeasured> {
        guard let standardField = fields["standard"] else {
            return .failure(.exemptionsMalformed(line: itemLine, detail: "missing 'standard'"))
        }
        guard let standard = Standard(rawValue: standardField.value) else {
            return .failure(
                .exemptionsMalformed(
                    line: standardField.line, detail: "unknown standard '\(standardField.value)'"))
        }
        guard let reasonField = fields["reason"] else {
            return .failure(.exemptionsMalformed(line: itemLine, detail: "missing 'reason'"))
        }
        guard !reasonField.value.trimmed().isEmpty else {
            return .failure(.exemptionsMalformed(line: reasonField.line, detail: "blank 'reason'"))
        }
        guard let grantedByField = fields["granted_by"] else {
            return .failure(.exemptionsMalformed(line: itemLine, detail: "missing 'granted_by'"))
        }
        guard !grantedByField.value.trimmed().isEmpty else {
            return .failure(.exemptionsMalformed(line: grantedByField.line, detail: "blank 'granted_by'"))
        }
        guard let grantedAtField = fields["granted_at"] else {
            return .failure(.exemptionsMalformed(line: itemLine, detail: "missing 'granted_at'"))
        }
        guard let grantedAt = Self.date(grantedAtField.value) else {
            return .failure(
                .exemptionsMalformed(
                    line: grantedAtField.line, detail: "malformed date '\(grantedAtField.value)'"))
        }

        var expires: Date?
        if let expiresField = fields["expires"] {
            guard let parsed = Self.date(expiresField.value) else {
                return .failure(
                    .exemptionsMalformed(
                        line: expiresField.line, detail: "malformed date '\(expiresField.value)'"))
            }
            expires = parsed
        }

        var evidence: String?
        if let evidenceField = fields["evidence"], !evidenceField.value.isEmpty {
            evidence = evidenceField.value
        }

        let exemption = Exemption(
            standard: standard, reason: reasonField.value, grantedBy: grantedByField.value,
            grantedAt: grantedAt, expires: expires, evidence: evidence)
        return .success((exemption, next))
    }

    /// `>` folded: every following line indented deeper than the key joins
    /// with a single space, trimmed. A blank line ends it — the subset this
    /// parser accepts has no exemption whose reason needs a paragraph break,
    /// and treating "nothing here" as still-inside would blur the two.
    ///
    /// Unlike an ordinary `key: value` line, this never runs the text through
    /// `withoutComment`: block scalar content is literal, the same reason a
    /// `#` inside a URL survives on a `key: value` line.
    private static func consumeFolded(
        _ lines: [Line], from start: Int, deeperThan indent: Int
    ) -> Result<(text: String, next: Int), Unmeasured> {
        var parts: [String] = []
        var pos = start

        while pos < lines.count {
            let (number, raw) = lines[pos]
            guard let lineIndent = Self.leadingSpaces(raw) else {
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { break }
                return .failure(
                    .exemptionsMalformed(line: number, detail: "tabs are not supported for indentation"))
            }
            let rest = String(raw.dropFirst(lineIndent))
            guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            guard lineIndent > indent else { break }
            parts.append(rest.trimmed())
            pos += 1
        }

        return .success((parts.joined(separator: " ").trimmed(), pos))
    }

    // MARK: - Lines

    private typealias Line = (number: Int, raw: String)

    /// CRLF and a lone CR both become LF, the same normalisation
    /// `IssueMarkdownParser.lines(of:)` applies, and for the same reason: a
    /// stray `\r` left in place turns every trailing token into one that
    /// matches nothing.
    private static func numberedLines(of text: String) -> [Line] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .enumerated()
            .map { (number: $0.offset + 1, raw: $0.element) }
    }

    private enum StepResult {
        case skip
        case line(indent: Int, text: String)
    }

    /// Blank and comment-only lines are `.skip`; a line whose indentation
    /// uses a tab is a refusal — indentation in this subset is spaces only.
    private static func step(_ lines: [Line], _ pos: Int) -> Result<StepResult, Unmeasured> {
        let (number, raw) = lines[pos]
        guard let indent = Self.leadingSpaces(raw) else {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { return .success(.skip) }
            return .failure(
                .exemptionsMalformed(line: number, detail: "tabs are not supported for indentation"))
        }
        let rest = String(raw.dropFirst(indent))
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return .success(.skip) }
        let text = Self.withoutComment(rest).trimmed()
        return .success(text.isEmpty ? .skip : .line(indent: indent, text: text))
    }

    /// Leading spaces before the first non-space character, or `nil` the
    /// moment a tab appears in that run. A line made only of tabs is still a
    /// blank line to the caller — only a tab before real content refuses.
    private static func leadingSpaces(_ raw: String) -> Int? {
        var count = 0
        for character in raw {
            if character == " " {
                count += 1
            } else if character == "\t" {
                return nil
            } else {
                break
            }
        }
        return count
    }

    /// Strips a `#` comment, but only one that starts the (already
    /// indent-stripped) line or is preceded by whitespace — a `#` inside a
    /// URL such as `…/issues/61#comment` is not a comment and must survive.
    private static func withoutComment(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if character == "#", previous == nil || previous == " " || previous == "\t" {
                break
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// `key: value`, requiring a space (or end of line) after the colon so a
    /// bare value with a colon of its own — a URL's `https:`, say — is never
    /// mistaken for a second key. Only the first colon is ever significant:
    /// whatever follows it, colons included, is the value.
    private static func splitKeyValue(_ text: String) -> (key: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[text.startIndex..<colon]).trimmed()
        guard !key.isEmpty else { return nil }
        let afterColon = text.index(after: colon)
        guard afterColon == text.endIndex || text[afterColon] == " " else { return nil }
        return (key, String(text[afterColon...]).trimmed())
    }

    /// Strips one matching pair of wrapping quotes. `reason: "   "` must
    /// still read as a blank reason, not as the four-character string of
    /// quotes-and-spaces it would be if quoting were left in place.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last, first == last,
            first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// `YYYY-MM-DD`, pinned to a fixed locale and time zone. Built per call
    /// rather than cached in a `static let`: `DateFormatter` is a class with
    /// mutable state and is not `Sendable`, the same reason
    /// `ShippingLog.screenshotURL(window:at:)` builds its own
    /// `ISO8601DateFormatter` per call instead of sharing one. A handful of
    /// dates per exemptions file is not the part worth optimising.
    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: Self.unquote(text))
    }
}
