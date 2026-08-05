import Foundation

/// Turns whatever an analysis run produced into stories.
///
/// The contract is the stream-json decoder's: **never throws, never drops
/// silently.** A model that emits one malformed story out of twelve should cost
/// one story, not the run; and every discarded story leaves a sentence saying
/// why, because "we found 8" and "we found 12 and threw 4 away" are different
/// results and the reader is entitled to know which one they are looking at.
public enum ProposalDecoder {
    public struct Harvest: Sendable, Hashable {
        public var stories: [ProposedStory]
        public var dropped: [String]

        public init(stories: [ProposedStory] = [], dropped: [String] = []) {
            self.stories = stories
            self.dropped = dropped
        }
    }

    /// The artifact the prompt asked for.
    public static func decode(artifact data: Data, maxStories: Int) -> Harvest {
        guard !data.isEmpty else {
            return Harvest(dropped: ["The artifact was empty."])
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return Harvest(dropped: ["The artifact was not valid JSON."])
        }
        return decode(jsonObject: raw, maxStories: maxStories)
    }

    /// The fallback: a fenced JSON block in the closing message.
    public static func decode(resultText: String, maxStories: Int) -> Harvest {
        guard let block = lastFencedJSONBlock(in: resultText) else {
            return Harvest(dropped: ["No JSON block was found in the closing message."])
        }
        return decode(artifact: Data(block.utf8), maxStories: maxStories)
    }

    private static func decode(jsonObject raw: Any, maxStories: Int) -> Harvest {
        // A bare array is what was asked for; a wrapped one is what models
        // reach for anyway. Both are the same intent.
        let elements: [Any]
        switch raw {
        case let array as [Any]:
            elements = array
        case let object as [String: Any]:
            guard let array = (object["stories"] ?? object["proposals"]) as? [Any] else {
                return Harvest(dropped: ["The JSON was an object with no \"stories\" array."])
            }
            elements = array
        default:
            return Harvest(dropped: ["The JSON was neither an array nor an object."])
        }

        guard !elements.isEmpty else {
            return Harvest(dropped: ["The JSON contained no stories."])
        }

        var kept: [ProposedStory] = []
        var dropped: [String] = []

        for (index, element) in elements.enumerated() {
            guard let _ = element as? [String: Any] else {
                dropped.append("Story \(index + 1) was not an object with the expected shape.")
                continue
            }
            guard
                let data = try? JSONSerialization.data(withJSONObject: element),
                let story = try? JSONDecoder().decode(ProposedStory.self, from: data)
            else {
                dropped.append("Story \(index + 1) was not an object with the expected shape.")
                continue
            }
            guard story.isUsable else {
                dropped.append(reasonUnusable(story, index: index))
                continue
            }
            kept.append(story)
        }

        if kept.count > maxStories {
            dropped.append(
                "\(kept.count - maxStories) stories over the cap of \(maxStories) were dropped."
            )
            kept = Array(kept.prefix(maxStories))
        }

        return Harvest(stories: kept, dropped: dropped)
    }

    private static func reasonUnusable(_ story: ProposedStory, index: Int) -> String {
        let name = story.title.trimmed().isEmpty ? "Story \(index + 1)" : "\"\(story.title)\""
        var missing: [String] = []
        if story.title.trimmed().isEmpty { missing.append("title") }
        if story.role.trimmed().isEmpty { missing.append("role") }
        if story.want.trimmed().isEmpty { missing.append("want") }
        if story.benefit.trimmed().isEmpty { missing.append("benefit") }
        if story.evidence.isEmpty { missing.append("evidence") }
        return "\(name) was dropped: missing \(missing.joined(separator: ", "))."
    }

    /// The last fenced block that looks like JSON.
    ///
    /// The last, not the first: a model that echoes the requested schema before
    /// answering would otherwise have its example harvested instead of its work.
    static func lastFencedJSONBlock(in text: String) -> String? {
        var blocks: [String] = []
        var remainder = text[...]

        while let open = remainder.range(of: "```") {
            let afterOpen = remainder[open.upperBound...]
            // Drop a language tag if there is one.
            let bodyStart = afterOpen.firstIndex(of: "\n").map(afterOpen.index(after:))
                ?? afterOpen.startIndex
            let body = afterOpen[bodyStart...]
            guard let close = body.range(of: "```") else { break }
            blocks.append(String(body[..<close.lowerBound]))
            remainder = body[close.upperBound...]
        }

        return blocks.reversed().first { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
        }
    }
}
