import AVFoundation
import Testing
@testable import Camlab

struct CameraOutputValidationTests {
    @Test func unsettledGainsStayInsideConversionLimits() throws {
        for value: Float in [0, -1, .nan, .infinity, -.infinity, 9] {
            let gains = try #require(CameraOutputValidation.whiteBalanceGains(
                .init(redGain: value, greenGain: value, blueGain: value), maximum: 4
            ))
            for channel in [gains.redGain, gains.greenGain, gains.blueGain] {
                #expect(channel.isFinite)
                #expect((1...4).contains(channel))
            }
        }
    }

    @Test func validGainsKeepTheirReadback() throws {
        let gains = try #require(CameraOutputValidation.whiteBalanceGains(
            .init(redGain: 1, greenGain: 2.5, blueGain: 4), maximum: 4
        ))
        #expect(gains.redGain == 1)
        #expect(gains.greenGain == 2.5)
        #expect(gains.blueGain == 4)
    }

    @Test func unavailableGainLimitSkipsConversion() {
        for maximum: Float in [0, -1, .nan, .infinity] {
            #expect(CameraOutputValidation.whiteBalanceGains(
                .init(redGain: 1, greenGain: 1, blueGain: 1), maximum: maximum
            ) == nil)
        }
    }

    @Test func switchingFormatsUsesOnlyTheNewSupportedDimensions() throws {
        let rear = [CMVideoDimensions(width: 8064, height: 6048),
                    CMVideoDimensions(width: 4032, height: 3024),
                    CMVideoDimensions(width: 5712, height: 4284)]
        let front = [CMVideoDimensions(width: 3840, height: 2160)]
        for supported in [rear, front, rear, front] {
            let selected = try #require(CameraOutputValidation.photoDimensions(from: supported))
            #expect(supported.contains { $0.width == selected.width && $0.height == selected.height })
            #expect(selected.width == (supported.count == 1 ? 3840 : 5712))
        }
    }

    @Test func missingDimensionsDoNotProduceAnInvalidOutputSetting() {
        #expect(CameraOutputValidation.photoDimensions(from: []) == nil)
        #expect(CameraOutputValidation.photoDimensions(from: [.init(width: 0, height: 0)]) == nil)
    }

    @Test func oversizedFormatsUseTheSmallestSupportedSize() throws {
        let size = try #require(CameraOutputValidation.photoDimensions(from: [
            .init(width: 10000, height: 8000), .init(width: 8000, height: 6000)
        ]))
        #expect(size.width == 8000 && size.height == 6000)
    }
}
