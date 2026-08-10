import Foundation
import Testing

@testable import ElliotModel

/// The decoder's contract is `ProposalDecoder`'s: **never throws, never drops
/// silently.** What differs is what "nothing usable" is allowed to become. A
/// proposal that cannot be read costs one story out of twelve; an appraisal that
/// cannot be read costs the card its measurement, so the absence has to stay
/// expressible — `appraisal == nil` — rather than degrade into a value some
/// ranking will later sort on.
@Suite("Appraisal decoder")
struct AppraisalDecoderTests {

    private func decode(_ json: String) -> AppraisalDecoder.Reading {
        AppraisalDecoder.decode(artifact: Data(json.utf8))
    }

    @Test("A good artifact yields both signals")
    func goodArtifact() throws {
        let reading = decode("""
            {"effort":"small","evidence":["Sources/A.swift:12","Sources/B.swift"]}
            """)
        let appraisal = try #require(reading.appraisal)
        #expect(appraisal.effort == .small)
        #expect(appraisal.evidence == ["Sources/A.swift:12", "Sources/B.swift"])
        #expect(reading.dropped.isEmpty)
    }

    @Test("An empty artifact is nothing, and says so")
    func emptyArtifact() {
        let reading = AppraisalDecoder.decode(artifact: Data())
        #expect(reading.appraisal == nil)
        #expect(reading.dropped == ["The artifact was empty."])
    }

    @Test("An artifact that is not JSON is nothing, and says so")
    func notJSON() {
        let reading = decode("I had a look and I think this is medium.")
        #expect(reading.appraisal == nil)
        #expect(reading.dropped.contains { $0.contains("not valid JSON") })
    }

    @Test("Valid JSON of the wrong shape is nothing, and says so")
    func wrongShape() {
        let reading = decode("[\"small\"]")
        #expect(reading.appraisal == nil)
        #expect(reading.dropped.contains { $0.contains("not a JSON object") })
    }

    @Test("An object with neither field is nothing, and says so")
    func emptyObject() {
        let reading = decode("{\"notes\":\"could not tell\"}")
        #expect(reading.appraisal == nil)
        #expect(reading.dropped.contains { $0.contains("neither an effort nor") })
    }

    @Test("\"unstated\" is a real answer, and it is not medium")
    func unstatedIsNotMedium() {
        // The joint constraint with PR2, made executable. If this reports
        // `.medium`, `Effort.parse` still folds silence onto a size and an
        // unattended ranking would be sorting on an invention.
        #expect(Effort.parse("") == .unstated)
        let reading = decode("{\"effort\":\"unstated\",\"evidence\":[]}")
        #expect(reading.appraisal?.effort == .unstated)
        #expect(reading.appraisal?.evidence.isEmpty == true)
    }

    @Test("An unrecognised effort degrades to unstated, never to a size")
    func unrecognisedEffortIsUnstated() {
        #expect(decode("{\"effort\":\"XL\",\"evidence\":[\"a.swift\"]}").appraisal?.effort == .unstated)
        #expect(decode("{\"evidence\":[\"a.swift\"]}").appraisal?.effort == .unstated)
    }

    @Test("Evidence alone is enough; effort alone is enough")
    func eitherFieldIsEnough() {
        #expect(decode("{\"evidence\":[\"a.swift\"]}").appraisal != nil)
        #expect(decode("{\"effort\":\"large\"}").appraisal?.evidence.isEmpty == true)
    }

    @Test("Blank and non-string citations are dropped with their reasons")
    func junkCitationsAreNamedNotSwallowed() throws {
        let reading = decode("""
            {"effort":"medium","evidence":["a.swift","   ",7,"b.swift"]}
            """)
        let appraisal = try #require(reading.appraisal)
        #expect(appraisal.evidence == ["a.swift", "b.swift"])
        #expect(reading.dropped.count == 2)
        #expect(reading.dropped.contains { $0.contains("2") })
        #expect(reading.dropped.contains { $0.contains("3") })
    }

    @Test("Evidence of the wrong type is dropped, and the effort survives")
    func evidenceOfTheWrongTypeDoesNotCostTheEffort() {
        let reading = decode("{\"effort\":\"large\",\"evidence\":\"Sources/A.swift\"}")
        #expect(reading.appraisal?.effort == .large)
        #expect(reading.appraisal?.evidence.isEmpty == true)
        #expect(reading.dropped.contains { $0.contains("was not a list") })
    }

    @Test("There is no closing-message fallback, by construction")
    func thereIsNoResultTextEntryPoint() {
        // `ProposalDecoder` has `decode(resultText:)`. This one deliberately
        // does not, so no caller can reach for it: an appraisal salvaged from
        // prose would be prose persisted into a card field. The witness is that
        // a fenced block reaching the only entry point decodes to nothing.
        let reading = AppraisalDecoder.decode(
            artifact: Data("```json\n{\"effort\":\"small\"}\n```".utf8))
        #expect(reading.appraisal == nil)
    }
}
