import CoreImage
import Testing
@testable import Camlab

struct PreviewGeometryTests {
    private var source: CIImage {
        let bounds = CGRect(x: 0, y: 0, width: 2, height: 3)
        var image = CIImage(color: .white).cropped(to: bounds)
        let corners: [(CGFloat, CGFloat, CIColor)] = [
            (0, 0, .red), (1, 0, .blue), (0, 2, .green), (1, 2, CIColor(red: 1, green: 1, blue: 0))
        ]
        for (x, y, color) in corners {
            image = CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: 1, height: 1)).composited(over: image)
        }
        return image
    }

    private func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { output in
            CIContext().render(image, toBitmap: output.baseAddress!, rowBytes: 4,
                               bounds: CGRect(x: x, y: y, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return Array(bytes.prefix(3))
    }

    @Test func portraitRotationPreservesFramingAndCornerPositions() {
        let portrait = PreviewGeometry.oriented(source, clockwiseDegrees: 90, mirrored: false)
        #expect(portrait.extent == CGRect(x: 0, y: 0, width: 3, height: 2))
        #expect(pixel(portrait, x: 0, y: 1) == [255, 0, 0])
        #expect(pixel(portrait, x: 0, y: 0) == [0, 0, 255])
        #expect(pixel(portrait, x: 2, y: 1) == [0, 255, 0])
    }

    @Test func frontCameraMirrorsAfterRotation() {
        let portrait = PreviewGeometry.oriented(source, clockwiseDegrees: 90, mirrored: true)
        #expect(portrait.extent == CGRect(x: 0, y: 0, width: 3, height: 2))
        #expect(pixel(portrait, x: 2, y: 1) == [255, 0, 0])
        #expect(pixel(portrait, x: 2, y: 0) == [0, 0, 255])
        #expect(pixel(portrait, x: 0, y: 1) == [0, 255, 0])
    }

    @Test(arguments: [CGFloat(0), 90, 180, 270, 360, -90])
    func quarterTurnsHaveExactPixelDimensions(angle: CGFloat) {
        let image = PreviewGeometry.oriented(source, clockwiseDegrees: angle, mirrored: false)
        let swapsAxes = abs(angle.truncatingRemainder(dividingBy: 180)) == 90
        #expect(image.extent == CGRect(x: 0, y: 0, width: swapsAxes ? 3 : 2, height: swapsAxes ? 2 : 3))
    }
}
