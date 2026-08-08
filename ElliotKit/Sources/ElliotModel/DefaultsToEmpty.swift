import Foundation

/// A `[String]` that decodes to `[]` when the key is simply not there.
///
/// ### Why this exists
///
/// Swift's synthesised `init(from:)` **does not use a property's default
/// value**. `public var labels: [String] = []` still emits a plain
/// `decode(_:forKey:)`, which throws `keyNotFound` the moment it meets a row or
/// a payload written before the field existed. For an `Optional` the synthesis
/// emits `decodeIfPresent` and absence reads as `nil`; for a non-optional
/// collection there is no such courtesy.
///
/// That matters here because of a rule this codebase already committed to:
/// `BoardStore.openReadOnly` accepts a database **older** than the code reading
/// it (`applied.isSubset(of: known)`), so the MCP helper keeps answering in the
/// window between a new bundle being installed and the app next launching and
/// migrating. The comment on `OlderDatabaseTests` states the shape of that
/// tolerance exactly: it "was written for added *columns*, which read as
/// absent". A non-optional field silently opts out of it — every card decode
/// throws, and the helper reports the whole read as refused.
///
/// ### Why a wrapper rather than a hand-written `init(from:)`
///
/// `Card` has nineteen stored properties. Writing the initialiser out to make
/// one of them tolerant creates a second place every future field has to be
/// added, and the failure when someone forgets is a decode that drops data
/// rather than a compile error. This is one type, opted into per property, and
/// a new field costs nothing.
///
/// The mechanism is the `KeyedDecodingContainer` overload below: the compiler
/// resolves the synthesised `decode(_:forKey:)` call to it because it is more
/// specific than the generic `Decodable` one, and it asks `decodeIfPresent`
/// instead.
@propertyWrapper
public struct DefaultsToEmpty: Codable, Sendable, Hashable {
    public var wrappedValue: [String]

    public init(wrappedValue: [String]) {
        self.wrappedValue = wrappedValue
    }

    /// A single value, not a keyed one — so the encoded form is the bare JSON
    /// array a plain `[String]` would have produced. The wrapper must be
    /// invisible on the wire and in the column, or adopting it would itself be
    /// the migration it exists to avoid.
    public init(from decoder: any Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode([String].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

public extension KeyedDecodingContainer {
    /// Absence is `[]`, and an explicit `null` is too.
    ///
    /// `decodeIfPresent` returns `nil` for both, and both mean the same thing
    /// here: nobody said which labels this card wants. Distinguishing them
    /// would give the caller a difference with no meaning behind it.
    func decode(_ type: DefaultsToEmpty.Type, forKey key: Key) throws -> DefaultsToEmpty {
        try decodeIfPresent(type, forKey: key) ?? DefaultsToEmpty(wrappedValue: [])
    }
}
