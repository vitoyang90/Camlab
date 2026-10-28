import CoreImage
import Foundation

nonisolated enum PreviewGeometry {
    static func sensorPoint(sourceExtent: CGRect, clockwiseDegrees: CGFloat, mirrored: Bool,
                            viewport: CGSize, touch: CGPoint) -> CGPoint? {
        guard sourceExtent.width > 0, sourceExtent.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        var transform = CGAffineTransform(rotationAngle: -clockwiseDegrees * .pi / 180)
        if mirrored { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        let extent = sourceExtent.applying(transform)
        transform = transform.concatenating(CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = min(viewport.width / extent.width, viewport.height / extent.height)
        let offset = CGPoint(x: (viewport.width - extent.width * scale) / 2,
                             y: (viewport.height - extent.height * scale) / 2)
        guard touch.x >= offset.x, touch.y >= offset.y,
              touch.x <= viewport.width - offset.x, touch.y <= viewport.height - offset.y else { return nil }
        let pixel = CGPoint(x: (touch.x - offset.x) / scale,
                            y: (viewport.height - touch.y - offset.y) / scale).applying(transform.inverted())
        return CGPoint(x: min(1, max(0, (pixel.x - sourceExtent.minX) / sourceExtent.width)),
                       y: min(1, max(0, 1 - (pixel.y - sourceExtent.minY) / sourceExtent.height)))
    }

    static func oriented(_ source: CIImage, clockwiseDegrees: CGFloat, mirrored: Bool) -> CIImage {
        let angle = (clockwiseDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        var image: CIImage
        // Exact quarter turns avoid floating point expansion of pixel bounds.
        switch angle {
        case 0: image = source
        case 90: image = source.oriented(.right)
        case 180: image = source.oriented(.down)
        case 270: image = source.oriented(.left)
        default: image = source.transformed(by: CGAffineTransform(rotationAngle: -angle * .pi / 180))
        }
        if mirrored { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
