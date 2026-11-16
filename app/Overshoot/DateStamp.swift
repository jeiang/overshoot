import CoreGraphics
import CoreText
import Foundation
import UIKit

/// The Canon orange date stamp, burnt into the sensor-oriented image like the real camera does.
/// Geometry measured on 1024x768 reference photos.
enum DateStamp {
    private static let glyphHeightFraction: CGFloat = 0.0286
    private static let pitchPerGlyphHeight: CGFloat = 0.68
    private static let rightEdgeFraction: CGFloat = 0.932
    private static let digitBottomFraction: CGFloat = 0.872
    private static let fill = CGColor(srgbRed: 232 / 255, green: 165 / 255, blue: 62 / 255, alpha: 1)
    private static let outline = CGColor(srgbRed: 46 / 255, green: 30 / 255, blue: 10 / 255, alpha: 1)

    static func text(date: Date, includeTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = includeTime ? "yyyy/MM/dd HH:mm" : "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    /// DIN Condensed Bold when installed, else the monospaced-digit system font.
    private static func baseFont() -> CTFont {
        let din = CTFontCreateWithName("DINCondensed-Bold" as CFString, 100, nil)
        let family = CTFontCopyFamilyName(din) as String
        if family == "DIN Condensed" { return din }
        return UIFont.monospacedDigitSystemFont(ofSize: 100, weight: .bold) as CTFont
    }

    static func draw(in context: CGContext, date: Date, includeTime: Bool) {
        let width = CGFloat(context.width)
        let height = CGFloat(context.height)
        let glyphHeight = glyphHeightFraction * height
        let base = baseFont()
        let capHeightPerPoint = CTFontGetCapHeight(base) / CTFontGetSize(base)
        let font = CTFontCreateCopyWithAttributes(base, glyphHeight / capHeightPerPoint, nil, nil)
        let pitch = pitchPerGlyphHeight * glyphHeight
        let characters = Array(text(date: date, includeTime: includeTime).utf16)
        let baselineY = height * (1 - digitBottomFraction)
        var x = rightEdgeFraction * width - pitch * CGFloat(characters.count)
        let path = CGMutablePath()
        for character in characters {
            var unit = character
            var glyph = CGGlyph(0)
            if CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1) {
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                var transform = CGAffineTransform(translationX: x + (pitch - advance.width) / 2, y: baselineY)
                if let glyphPath = CTFontCreatePathForGlyph(font, glyph, &transform) {
                    path.addPath(glyphPath)
                }
            }
            x += pitch
        }
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(outline)
        context.setLineWidth(0.09 * glyphHeight)
        context.setLineJoin(.round)
        context.strokePath()
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.restoreGState()
    }
}
