import Testing
@testable import Camlab

struct CameraZoomScaleTests {
    @Test func virtualCameraPresetsUseDisplayMagnification() {
        let triple = CameraZoomScale(hardwareRange: 1...100, displayMultiplier: 0.5)
        #expect(triple.presets(switchOverFactors: [2, 10]) == [0.5, 1, 2, 5])
        let dualWide = CameraZoomScale(hardwareRange: 1...20, displayMultiplier: 0.5)
        #expect(dualWide.presets(switchOverFactors: [2]) == [0.5, 1, 2])
        let single = CameraZoomScale(hardwareRange: 1...1.5, displayMultiplier: 1)
        #expect(single.presets(switchOverFactors: []) == [1])
        #expect(triple.displayed(triple.hardwareFactor(for: 1)) == 1)
    }

    @Test func flipOnlyChangesCameraFacing() {
        let back = CameraChoice(id: "back", name: "後置相機", isFront: false)
        let front = CameraChoice(id: "front", name: "前置相機", isFront: true)
        #expect(CameraChoice.flipTarget(in: [back, front], currentID: "back")?.id == "front")
        #expect(CameraChoice.flipTarget(in: [back, front], currentID: "front")?.id == "back")
        #expect(CameraChoice.flipTarget(in: [back], currentID: "back") == nil)
        #expect(CameraChoice.flipTarget(in: [back, front], currentID: "missing") == nil)
    }

    @Test func capsExtremeHardwareZoomAndClampsRestoredValues() {
        let scale = CameraZoomScale(hardwareRange: 1...100, displayMultiplier: 1)
        #expect(scale.displayRange == 1...10)
        #expect(scale.hardwareFactor(for: 80) == 10)
        #expect(scale.hardwareFactor(for: 0.5) == 1)
    }

    @Test func displayLimitIsConsistentAcrossLensMultipliers() {
        let wide = CameraZoomScale(hardwareRange: 1...100, displayMultiplier: 1)
        let ultraWide = CameraZoomScale(hardwareRange: 1...100, displayMultiplier: 0.5)
        let telephoto = CameraZoomScale(hardwareRange: 1...100, displayMultiplier: 5)
        #expect(ultraWide.displayRange == 0.5...10)
        #expect(ultraWide.hardwareFactor(for: 10) == 20)
        #expect(telephoto.hardwareFactor(for: 10) == 2)
        for scale in [wide, ultraWide, telephoto] {
            #expect(scale.displayed(scale.hardwareFactor(for: 10)) == 10)
        }
    }

    @Test func preservesLowerHardwareLimitsAndFixedRanges() {
        let limited = CameraZoomScale(hardwareRange: 1...4, displayMultiplier: 0.5)
        #expect(limited.displayRange == 0.5...2)
        #expect(limited.hardwareFactor(for: 10) == 4)
        let fixed = CameraZoomScale(hardwareRange: 1...1, displayMultiplier: 1)
        #expect(fixed.displayRange == 1...1)
        #expect(fixed.hardwareFactor(for: 10) == 1)
    }

    @Test func bothLiveAndFullSettingsRejectZoomBeyondAppLimit() throws {
        let scale = CameraZoomScale(hardwareRange: 1...100, displayMultiplier: 0.5)
        let capabilities = CameraCapabilities(iso: 25...1600, shutter: (1.0 / 8000)...1,
                                              zoom: scale.displayRange, manualExposure: true,
                                              manualFocus: true, manualWhiteBalance: true)
        try CameraLiveAdjustment.zoom(10).validate(for: capabilities)
        #expect(try CameraSettings(zoom: "10").validated(for: capabilities).zoom == 10)
        #expect(throws: CameraFailure.self) {
            try CameraLiveAdjustment.zoom(10.1).validate(for: capabilities)
        }
        #expect(throws: CameraFailure.self) {
            try CameraSettings(zoom: "10.1").validated(for: capabilities)
        }
    }
}
