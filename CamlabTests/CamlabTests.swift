import CoreImage
import Testing
@testable import Camlab

struct CamlabTests {
    private var capabilities: CameraCapabilities {
        CameraCapabilities(iso: 25...1600, shutter: (1.0 / 8000)...1, zoom: 1...10,
                           manualExposure: true, manualFocus: true, manualWhiteBalance: true)
    }

    @Test func acceptsShutterFractionsAndSeconds() throws {
        #expect(try CameraSettings.exposureSeconds("1/125", range: capabilities.shutter) == 0.008)
        #expect(try CameraSettings.exposureSeconds(" 0.008 ", range: capabilities.shutter) == 0.008)
        #expect(try CameraSettings.exposureSeconds(" 1 / 125 ", range: capabilities.shutter) == 0.008)
    }

    @Test(arguments: ["1/0", "0/0", "-1/-125", "1/2/3", "nan", "inf", "0", "-0.2", "1/100000", "2", "", "/125", "1/"])
    func rejectsInvalidShutter(input: String) {
        #expect(throws: CameraFailure.self) {
            try CameraSettings.exposureSeconds(input, range: capabilities.shutter)
        }
    }

    @Test func validatesAllManualValues() throws {
        let draft = CameraSettings(automaticExposure: false, automaticFocus: false, automaticWhiteBalance: false,
                                   iso: "400", shutter: "1/125", focus: "0.8", temperature: "5600", tint: "-20", zoom: "2")
        let result = try draft.validated(for: capabilities)
        #expect(result.iso == 400)
        #expect(result.shutter == 0.008)
        #expect(result.focus == 0.8)
        #expect(result.temperature == 5600)
        #expect(result.tint == -20)
        #expect(result.zoom == 2)
    }

    @Test func automaticModesIgnoreUnsubmittedManualText() throws {
        let draft = CameraSettings(iso: "", shutter: "bad", focus: "nan", temperature: "", tint: "inf")
        let result = try draft.validated(for: capabilities)
        #expect(result.iso == nil && result.shutter == nil)
        #expect(result.focus == nil && result.temperature == nil && result.tint == nil)
    }

    @Test func unsupportedControlsAreNeverRequested() throws {
        var fixedLens = capabilities
        fixedLens.manualExposure = false
        fixedLens.manualFocus = false
        fixedLens.manualWhiteBalance = false
        let draft = CameraSettings(automaticExposure: false, automaticFocus: false, automaticWhiteBalance: false,
                                   iso: "bad", shutter: "bad", focus: "bad", temperature: "bad", tint: "bad")
        let result = try draft.validated(for: fixedLens)
        #expect(result.iso == nil && result.focus == nil && result.temperature == nil)
    }

    @Test(arguments: ["nan", "inf", "-inf", "", "abc", "0.5", "11"])
    func rejectsInvalidZoom(input: String) {
        let draft = CameraSettings(zoom: input)
        #expect(throws: CameraFailure.self) { try draft.validated(for: capabilities) }
    }

    @Test func usesCurrentLensBounds() throws {
        let draft = CameraSettings(automaticExposure: false, iso: "100", shutter: "1/125")
        _ = try draft.validated(for: capabilities)
        var narrowRange = capabilities
        narrowRange.iso = 200...1600
        #expect(throws: CameraFailure.self) { try draft.validated(for: narrowRange) }
    }

    @Test func rejectsOutOfRangeFocusAndWhiteBalance() {
        for draft in [
            CameraSettings(automaticFocus: false, focus: "1.1"),
            CameraSettings(automaticWhiteBalance: false, temperature: "1500"),
            CameraSettings(automaticWhiteBalance: false, tint: "151")
        ] {
            #expect(throws: CameraFailure.self) { try draft.validated(for: capabilities) }
        }
    }

    @Test func validatesExposureCompensationAgainstLensRange() throws {
        #expect(try CameraSettings(exposureBias: "-1.3").validated(for: capabilities).exposureBias == -1.3)
        #expect(throws: CameraFailure.self) {
            try CameraSettings(exposureBias: "4").validated(for: capabilities)
        }
        #expect(throws: CameraFailure.self) {
            try CameraSettings(exposureBias: "nan").validated(for: capabilities)
        }
        let manual = CameraSettings(automaticExposure: false, exposureBias: "bad")
        #expect(try manual.validated(for: capabilities).exposureBias == nil)
    }

    @Test func stylePresetsProduceValidParameters() throws {
        for preset in PhotoStyle.allCases {
            #expect(try StyleDraft(preset.adjustment).validated() == preset.adjustment)
        }
        var draft = StyleDraft()
        draft.warmth = "nan"
        #expect(throws: CameraFailure.self) { try draft.validated() }
        draft = StyleDraft()
        draft.saturation = "3"
        #expect(throws: CameraFailure.self) { try draft.validated() }
    }

    @Test func stylesChangeRenderedPixels() {
        let colorful = CIImage(color: CIColor(red: 0.65, green: 0.35, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let natural = pixel(PhotoStyle.natural.adjustment.applying(to: colorful))
        let mono = pixel(PhotoStyle.mono.adjustment.applying(to: colorful))
        #expect(abs(mono[0] - mono[1]) < 0.01 && abs(mono[1] - mono[2]) < 0.01)
        #expect(abs(natural[0] - mono[0]) > 0.05)
        let vivid = pixel(PhotoStyle.vivid.adjustment.applying(to: colorful))
        #expect(vivid[0] - vivid[2] > natural[0] - natural[2])

        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: colorful.extent)
        let warm = pixel(PhotoStyle.warm.adjustment.applying(to: gray))
        let cool = pixel(PhotoStyle.cool.adjustment.applying(to: gray))
        #expect(warm[0] > warm[2])
        #expect(cool[2] > cool[0])
        let restored = pixel(StyleAdjustment().applying(to: colorful))
        #expect(zip(natural, restored).allSatisfy { abs($0 - $1) < 0.001 })
    }

    private func pixel(_ image: CIImage) -> [Float] {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return values
    }
}
