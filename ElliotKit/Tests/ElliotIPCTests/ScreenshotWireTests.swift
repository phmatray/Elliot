import ElliotModel
import Foundation
import Testing

@testable import ElliotIPC

@Suite("Screenshot wire format")
struct ScreenshotWireTests {

    /// 5: the wire can carry a picture of a window. A 5 helper sending
    /// `.screenshot` to a 4 app sends a case that app cannot decode, so the
    /// pairing has to be refused at the handshake rather than halfway through a
    /// request — which is the whole job of this number.
    ///
    /// A floor rather than an equality, changed by #174 when it took the wire to
    /// 6. The claim this test makes is *"screenshot needs at least 5"*, and that
    /// stays true for ever; `== 5` additionally asserted that no later feature
    /// would touch the wire, which is not a property of this feature and made
    /// every subsequent bump edit a screenshot test to say so.
    ///
    /// Note what neither form catches: adding a field and forgetting to bump.
    /// `==` only forced an edit, it never proved one was warranted.
    @Test("The protocol version is at least the one screenshot needs")
    func versionBumped() {
        #expect(elliotProtocolVersion >= 5)
    }

    @Test("A screenshot request round-trips through the wire codec", arguments: [
        ElliotRequest.screenshot(window: "board", maxInlineBytes: 768 * 1024),
        .screenshot(window: "preflight", maxInlineBytes: 0),
    ])
    func requestRoundTrips(request: ElliotRequest) throws {
        let line = try WireCodec.encodeLine(Envelope(body: request))
        let back = try WireCodec.decode(Envelope<ElliotRequest>.self, from: line.dropLast())
        #expect(back.body == request)
    }

    @Test("A capture that could not be inlined round-trips as one that could not")
    func absentImageSurvives() throws {
        // `pngBase64: nil` and a populated `notIncluded` are the two fields most
        // likely to be quietly dropped, and they are the two an agent reads to
        // learn that the picture is incomplete. A DTO that lost them would report
        // a partial capture as a whole one.
        let dto = ScreenshotDTO(
            window: "board",
            title: "Elliot",
            width: 900,
            height: 700,
            scale: 2,
            pngPath: "/tmp/shot.png",
            pngBase64: nil,
            byteCount: 0,
            downscaledFrom: 2,
            isVisible: false,
            isKeyWindow: false,
            notIncluded: ["attached sheet: New story", "1 child window"]
        )

        let data = try WireCodec.encoder.encode(dto)
        let back = try WireCodec.decoder.decode(ScreenshotDTO.self, from: data)

        #expect(back == dto)
        #expect(back.pngBase64 == nil)
        #expect(back.notIncluded.count == 2)
        #expect(back.downscaledFrom == 2)
        #expect(back.isVisible == false)
    }

    @Test("A screenshot payload round-trips inside a response")
    func payloadRoundTrips() throws {
        let dto = ScreenshotDTO(
            window: "operations",
            title: "Operations",
            width: 820,
            height: 720,
            scale: 2,
            pngPath: "/tmp/ops.png",
            pngBase64: "aGVsbG8=",
            byteCount: 8,
            downscaledFrom: nil,
            isVisible: true,
            isKeyWindow: true,
            notIncluded: []
        )
        let line = try WireCodec.encodeLine(Envelope(body: ElliotResponse.ok(.screenshot(dto))))
        let back = try WireCodec.decode(Envelope<ElliotResponse>.self, from: line.dropLast())

        guard case .ok(.screenshot(let decoded)) = back.body else {
            Issue.record("expected a screenshot payload, got \(back.body)")
            return
        }
        #expect(decoded == dto)
        // Absent rather than sent as `null`-ish noise: an agent reading
        // `downscaledFrom` set at all takes it as "this was resampled".
        #expect(decoded.downscaledFrom == nil)
    }

    @Test("A window that is not visible is still a valid capture")
    func hiddenIsNotAFailure() throws {
        // The measurement this whole feature rests on: `cacheDisplay` renders a
        // window whose `isVisible` is false, at full designed size. So `false`
        // here is a fact about the window, never a verdict on the picture — a
        // reader that treats it as failure re-creates the false negative the
        // tool exists to remove.
        let dto = ScreenshotDTO(
            window: "repositories", title: "Repositories",
            width: 900, height: 700, scale: 2,
            pngPath: "/tmp/r.png", pngBase64: "eA==", byteCount: 4,
            downscaledFrom: nil, isVisible: false, isKeyWindow: false, notIncluded: []
        )
        let back = try WireCodec.decoder.decode(
            ScreenshotDTO.self, from: try WireCodec.encoder.encode(dto)
        )
        #expect(back.isVisible == false)
        #expect(back.width == 900)
        #expect(back.height == 700)
    }
}
