import Testing
@testable import Camlab

struct CameraCaptureSettingsTests {
    private var capabilities: CameraCapabilities {
        .init(iso: 25...3200, shutter: (1.0 / 8000)...1, zoom: 0.5...10,
              manualExposure: true, manualFocus: true, manualWhiteBalance: true)
    }

    @Test func automaticFirstShotNeedsNoDeviceReconfiguration() throws {
        let draft = CameraSettings()
        var metered = draft
        metered.iso = "800"
        metered.shutter = "0.01"
        metered.focus = "0.8"
        metered.temperature = "6200"
        metered.tint = "12"
        #expect(try !draft.requiresApplication(comparedTo: metered, capabilities: capabilities))
    }

    @Test func equivalentNumericFormattingDoesNotDelayCapture() throws {
        var draft = CameraSettings()
        draft.automaticExposure = false
        var readback = draft
        readback.iso = "100.0"
        readback.shutter = "0.008"
        readback.zoom = "1.000"
        #expect(try !draft.requiresApplication(comparedTo: readback, capabilities: capabilities))
    }

    @Test func pendingManualEditsAreStillAppliedBeforeCapture() throws {
        let readback = CameraSettings()
        var iso = readback, focus = readback, temperature = readback, zoom = readback, bias = readback
        iso.automaticExposure = false; iso.iso = "400"
        focus.automaticFocus = false; focus.focus = "0.7"
        temperature.automaticWhiteBalance = false; temperature.temperature = "6000"
        zoom.zoom = "2"
        bias.exposureBias = "1"
        for draft in [iso, focus, temperature, zoom, bias] {
            #expect(try draft.requiresApplication(comparedTo: readback, capabilities: capabilities))
        }
    }

    @Test func returningToAutomaticModesIsNotSkipped() throws {
        let automatic = CameraSettings()
        var manual = automatic
        manual.automaticExposure = false
        manual.automaticFocus = false
        manual.automaticWhiteBalance = false
        #expect(try automatic.requiresApplication(comparedTo: manual, capabilities: capabilities))
    }

    @Test func invalidPendingEditsStillPreventCapture() {
        var invalid = CameraSettings()
        invalid.automaticExposure = false
        invalid.shutter = "invalid"
        #expect(throws: CameraFailure.self) {
            try invalid.requiresApplication(comparedTo: CameraSettings(), capabilities: capabilities)
        }
    }
}
