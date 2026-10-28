import Testing
@testable import Camlab

struct CameraLiveAdjustmentTests {
    private var capabilities: CameraCapabilities {
        CameraCapabilities(iso: 25...1600, shutter: (1.0 / 8000)...1, zoom: 1...10,
                           manualExposure: true, manualFocus: true, manualWhiteBalance: true)
    }

    @Test func rapidChangesKeepFinalValuesAndOtherControls() {
        var buffer = CameraAdjustmentBuffer()
        for index in 0..<1000 { buffer.enqueue(.zoom(Double(index))) }
        buffer.enqueue(.iso(200))
        buffer.enqueue(.shutter(0.008))
        buffer.enqueue(.iso(400))
        #expect(buffer.next() == .zoom(999))
        #expect(buffer.next() == .shutter(0.008))
        #expect(buffer.next() == .iso(400))
        #expect(buffer.next() == nil)
    }

    @Test func switchingAutoAndManualPreservesLastActionOrder() {
        var buffer = CameraAdjustmentBuffer()
        buffer.enqueue(.iso(100))
        buffer.enqueue(.automaticExposure)
        buffer.enqueue(.iso(400))
        #expect(buffer.next() == .automaticExposure)
        #expect(buffer.next() == .iso(400))
        buffer.enqueue(.focus(0.4))
        buffer.enqueue(.automaticFocus)
        #expect(buffer.next() == .automaticFocus)
        #expect(buffer.next() == nil)
    }

    @Test func liveZoomDoesNotCommitUnrelatedInvalidDrafts() {
        var draft = CameraSettings(automaticExposure: false, iso: "bad", shutter: "bad", temperature: "bad")
        CameraLiveAdjustment.zoom(2).updateDraft(&draft, readback: CameraSettings())
        #expect(draft.zoom == "2.0")
        #expect(draft.iso == "bad" && draft.shutter == "bad" && draft.temperature == "bad")
    }

    @Test func manualExposureStartsWithCurrentOtherValue() {
        var draft = CameraSettings(shutter: "1/125")
        let readback = CameraSettings(iso: "320", shutter: "0.01")
        CameraLiveAdjustment.iso(400).updateDraft(&draft, readback: readback)
        #expect(!draft.automaticExposure && draft.iso == "400.0" && draft.shutter == "0.01")
        CameraLiveAdjustment.shutter(0.008).updateDraft(&draft, readback: readback)
        #expect(draft.iso == "400.0" && draft.shutter == "0.008")
    }

    @Test func rejectedAdjustmentCanRestoreOnlyAffectedControl() {
        var draft = CameraSettings(automaticWhiteBalance: false, iso: "400", temperature: "10000", zoom: "3")
        let readback = CameraSettings(temperature: "5000")
        CameraLiveAdjustment.temperature(10000).restoreDraft(&draft, readback: readback)
        #expect(draft.automaticWhiteBalance && draft.temperature == "5000")
        #expect(draft.iso == "400" && draft.zoom == "3")
    }

    @Test func invalidOrUnsupportedValuesAreRejectedBeforeHardwareChanges() throws {
        for adjustment in [CameraLiveAdjustment.iso(.nan), .shutter(0), .focus(2), .temperature(1000), .zoom(11), .brightness(4)] {
            #expect(throws: CameraFailure.self) { try adjustment.validate(for: capabilities) }
        }
        var limited = capabilities
        limited.manualExposure = false
        limited.manualFocus = false
        limited.manualWhiteBalance = false
        for adjustment in [CameraLiveAdjustment.iso(100), .shutter(0.008), .focus(0.5), .temperature(5000)] {
            #expect(throws: CameraFailure.self) { try adjustment.validate(for: limited) }
        }
        try CameraLiveAdjustment.zoom(2).validate(for: limited)
    }
}
