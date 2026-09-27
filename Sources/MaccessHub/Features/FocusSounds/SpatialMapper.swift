import AVFoundation
import CoreGraphics
import Foundation

/// Maps a screen rectangle to a listener-relative direction, the way
/// unspoken-ng's spatial.py does: azimuth spans ±90° across the desktop's
/// width, elevation runs from -40° at the bottom to +10° at the top.
enum SpatialMapper {
    static let azimuthSpan = 180.0
    static let elevationMin = -40.0
    static let elevationMagnitude = 50.0

    /// Union of all active displays in the same top-left global space AX uses.
    static func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        return ids.prefix(Int(count)).map(CGDisplayBounds).reduce(CGRect.null) { $0.union($1) }
    }

    static func position(for frame: CGRect, in desktop: CGRect = desktopBounds()) -> AVAudio3DPoint {
        let objX = frame.midX
        let objY = frame.midY
        var angleX = 0.0
        var angleY = 0.0
        if desktop.width > 0 {
            angleX = Double((objX - desktop.midX) / desktop.width) * azimuthSpan
        }
        if desktop.height > 0 {
            // AX y grows downward; "percent" is how far up from the bottom the control sits.
            let percent = Double((desktop.maxY - objY) / desktop.height)
            angleY = elevationMagnitude * percent + elevationMin
        }
        angleX = max(-90, min(90, angleX))
        angleY = max(-90, min(90, angleY))
        let rx = angleX * .pi / 180
        let ry = angleY * .pi / 180
        return AVAudio3DPoint(x: Float(sin(rx) * cos(ry)), y: Float(sin(ry)), z: Float(-cos(rx) * cos(ry)))
    }

    /// Straight ahead, used when an element has no frame.
    static let center = AVAudio3DPoint(x: 0, y: 0, z: -1)
}
