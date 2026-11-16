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
    private static let fill = CGColor(srgbRed: 226 / 255, green: 157 / 255, blue: 40 / 255, alpha: 1)
    private static let outline = CGColor(srgbRed: 32 / 255, green: 10 / 255, blue: 0, alpha: 1)

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
    static let stroke: CGFloat = 0.14
    /// Dark outline visible outside the fill.
    static let outline: CGFloat = 0.06
    private static let radius: CGFloat = 0.2
    private static let left = stroke / 2
    private static let right = width - stroke / 2
    private static let bottom = stroke / 2
    private static let top = 1 - stroke / 2

    static func add(_ character: Character, to path: CGMutablePath, transform: CGAffineTransform) {
        let (l, r, b, t) = (left, right, bottom, top)
        switch character {
        case "0": polyline([(l, 0.5), (l, t), (r, t), (r, b), (l, b), (l, 0.5)], path, transform)
        case "1":
            polyline([(0.36, b - 0.02), (0.36, t), (0.17, t - 0.13)], path, transform, rounded: false)
        case "2": polyline([(l, 0.76), (l, t), (r, t), (r, 0.56), (l, 0.26), (l, b), (r + 0.02, b)], path, transform)
        case "3":
            polyline([(l, 0.76), (l, t), (r, t), (r, b), (l, b), (l, 0.24)], path, transform)
            polyline([(l + 0.12, 0.52), (r, 0.52)], path, transform, rounded: false)
        case "4":
            polyline([(l, t + 0.02), (l, 0.34), (r + 0.03, 0.34)], path, transform, rounded: false)
            polyline([(r - 0.06, t + 0.02), (r - 0.06, b - 0.02)], path, transform, rounded: false)
        case "5": polyline([(r + 0.02, t), (l, t), (l, 0.56), (r, 0.56), (r, b), (l, b), (l, 0.24)], path, transform)
        case "6": polyline([(r, 0.78), (r, t), (l, t), (l, b), (r, b), (r, 0.56), (l, 0.56)], path, transform)
        case "7": polyline([(l, 0.78), (l, t), (r, t), (r, 0.72), (l + 0.1, b - 0.02)], path, transform)
        case "8":
            polyline([(l + 0.03, 0.75), (l + 0.03, t), (r - 0.03, t), (r - 0.03, 0.52), (l + 0.03, 0.52), (l + 0.03, 0.75)], path, transform)
            polyline([(l, 0.26), (l, 0.52), (r, 0.52), (r, b), (l, b), (l, 0.26)], path, transform)
        case "9": polyline([(l, 0.22), (l, b), (r, b), (r, t), (l, t), (l, 0.44), (r, 0.44)], path, transform)
        case "/": polyline([(0.1, b - 0.04), (width - 0.1, t + 0.04)], path, transform, rounded: false)
        case ":":
            for y: CGFloat in [0.24, 0.66] {
                polyline([(width / 2, y - 0.03), (width / 2, y + 0.03)], path, transform, rounded: false)
            }
        default: break
        }
    }

    /// Adds a polyline whose interior corners are rounded, which gives the squarish curves.
    private static func polyline(
        _ points: [(CGFloat, CGFloat)],
        _ path: CGMutablePath,
        _ transform: CGAffineTransform,
        rounded: Bool = true
    ) {
        let cgPoints = points.map { CGPoint(x: $0.0, y: $0.1) }
        path.move(to: cgPoints[0], transform: transform)
        for index in 1..<cgPoints.count {
            if rounded, index < cgPoints.count - 1 {
                path.addArc(tangent1End: cgPoints[index], tangent2End: cgPoints[index + 1], radius: radius, transform: transform)
            } else {
                path.addLine(to: cgPoints[index], transform: transform)
            }
        }
    }
}
