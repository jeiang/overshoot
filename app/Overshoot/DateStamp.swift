import CoreGraphics
import Foundation

/// The Canon orange date stamp. Geometry, glyph shapes and colours are measured on 1024x768
/// reference photos. The stamp is drawn upright in the photo's display orientation, sized from
/// the displayed height, so portrait photos get a horizontal stamp at the bottom right.
enum DateStamp {
    private static let glyphHeightFraction: CGFloat = 0.0286
    private static let pitchPerGlyphHeight: CGFloat = 0.68
    private static let rightEdgeFraction: CGFloat = 0.932
    private static let digitBottomFraction: CGFloat = 0.872
    private static let fill = CGColor(srgbRed: 218 / 255, green: 138 / 255, blue: 28 / 255, alpha: 1)
    private static let outline = CGColor(srgbRed: 28 / 255, green: 8 / 255, blue: 0, alpha: 1)

    static func text(date: Date, includeTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = includeTime ? "yyyy/MM/dd HH:mm" : "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    /// `context` holds the sensor-oriented image; `orientation` is its EXIF orientation.
    static func draw(in context: CGContext, date: Date, includeTime: Bool, orientation: Int) {
        let sensorWidth = CGFloat(context.width)
        let sensorHeight = CGFloat(context.height)
        let swapped = orientation == 6 || orientation == 8
        let width = swapped ? sensorHeight : sensorWidth
        let height = swapped ? sensorWidth : sensorHeight
        let glyphHeight = glyphHeightFraction * height
        let pitch = pitchPerGlyphHeight * glyphHeight
        let characters = Array(text(date: date, includeTime: includeTime))
        var x = rightEdgeFraction * width - pitch * CGFloat(characters.count)
        let bottom = height * (1 - digitBottomFraction)
        let centerlines = CGMutablePath()
        for character in characters {
            let origin = CGAffineTransform(translationX: x + (pitch - Glyphs.width * glyphHeight) / 2, y: bottom)
                .scaledBy(x: glyphHeight, y: glyphHeight)
            Glyphs.add(character, to: centerlines, transform: origin)
            x += pitch
        }
        let shape = centerlines.copy(strokingWithWidth: Glyphs.stroke * glyphHeight, lineCap: .butt, lineJoin: .round, miterLimit: 1).normalized()
        context.saveGState()
        context.concatenate(displayToSensor(orientation: orientation, sensorWidth: sensorWidth, sensorHeight: sensorHeight))
        context.addPath(shape)
        context.setStrokeColor(outline)
        context.setLineWidth(2 * Glyphs.outline * glyphHeight)
        context.setLineJoin(.round)
        context.strokePath()
        context.addPath(shape)
        context.setFillColor(fill)
        context.fillPath()
        context.restoreGState()
    }

    /// Maps display coordinates (bottom-left origin) to the sensor bitmap's coordinates.
    private static func displayToSensor(orientation: Int, sensorWidth: CGFloat, sensorHeight: CGFloat) -> CGAffineTransform {
        switch orientation {
        case 6: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: sensorWidth, ty: 0)
        case 8: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: sensorHeight)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: sensorWidth, ty: sensorHeight)
        default: .identity
        }
    }
}

/// Centerline shapes of the stamp's heavy, rounded-square monospaced digits, in units of glyph
/// height with the origin at the bottom left. The stroke turns them into filled outlines.
private enum Glyphs {
    static let width: CGFloat = 0.58
    static let stroke: CGFloat = 0.13
    /// Dark outline visible outside the fill.
    static let outline: CGFloat = 0.06
    private static let left = stroke / 2
    private static let right = width - stroke / 2
    private static let bottom = stroke / 2
    private static let top = 1 - stroke / 2
    /// Half the glyph's inner width: corners with this radius make a fully round bowl.
    private static let round = (right - left) / 2

    /// A centerline point; `corner` is the radius that rounds the turn at this point.
    private typealias Point = (x: CGFloat, y: CGFloat, corner: CGFloat)

    static func add(_ character: Character, to path: CGMutablePath, transform: CGAffineTransform) {
        let (l, r, b, t, o) = (left, right, bottom, top, round)
        let lines: [[Point]] = switch character {
        case "0": [[(l, 0.5, 0), (l, t, o), (r, t, o), (r, b, o), (l, b, o), (l, 0.5, 0)]]
        case "1": [[(0.36, b - 0.02, 0), (0.36, t, 0), (0.17, t - 0.13, 0)]]
        case "2": [[(l, 0.7, 0), (l, t, o), (r, t, o), (r, 0.58, 0.2), (l, b, 0.03), (r + 0.02, b, 0)]]
        case "3": [
            [(l, 0.74, 0), (l, t, o), (r, t, o), (r, 0.53, 0.18), (l + 0.12, 0.53, 0)],
            [(l + 0.12, 0.53, 0), (r, 0.53, 0.18), (r, b, o), (l, b, o), (l, 0.26, 0)],
        ]
        case "4": [
            [(r - 0.05, t + 0.02, 0), (l, 0.34, 0.02), (r + 0.03, 0.34, 0)],
            [(r - 0.05, t + 0.02, 0), (r - 0.05, b - 0.02, 0)],
        ]
        case "5": [[(r + 0.01, t, 0), (l, t, 0.02), (l, 0.56, 0.02), (r, 0.56, 0.2), (r, b, o), (l, b, o), (l, 0.25, 0)]]
        case "6": [[(r, 0.76, 0), (r, t, o), (l, t, o), (l, b, o), (r, b, o), (r, 0.58, 0.18), (l, 0.58, 0)]]
        case "7": [[(l, 0.8, 0), (l, t, 0.03), (r, t, 0.03), (r, 0.74, 0.12), (l + 0.12, b - 0.02, 0)]]
        case "8": [
            [(l + 0.03, 0.73, 0), (l + 0.03, t, 0.17), (r - 0.03, t, 0.17), (r - 0.03, 0.53, 0.17), (l + 0.03, 0.53, 0.17), (l + 0.03, 0.73, 0)],
            [(l, 0.27, 0), (l, 0.53, 0.18), (r, 0.53, 0.18), (r, b, o), (l, b, o), (l, 0.27, 0)],
        ]
        case "9": [[(l, 0.24, 0), (l, b, o), (r, b, o), (r, t, o), (l, t, o), (l, 0.42, 0.18), (r, 0.42, 0)]]
        case "/": [[(0.1, b - 0.04, 0), (width - 0.1, t + 0.04, 0)]]
        case ":": [[(width / 2, 0.21, 0), (width / 2, 0.27, 0)], [(width / 2, 0.63, 0), (width / 2, 0.69, 0)]]
        default: []
        }
        for line in lines { polyline(line, path, transform) }
    }

    private static func polyline(_ points: [Point], _ path: CGMutablePath, _ transform: CGAffineTransform) {
        path.move(to: CGPoint(x: points[0].x, y: points[0].y), transform: transform)
        for index in 1..<points.count {
            let point = CGPoint(x: points[index].x, y: points[index].y)
            if points[index].corner > 0, index < points.count - 1 {
                let next = CGPoint(x: points[index + 1].x, y: points[index + 1].y)
                path.addArc(tangent1End: point, tangent2End: next, radius: points[index].corner, transform: transform)
            } else {
                path.addLine(to: point, transform: transform)
            }
        }
    }
}
