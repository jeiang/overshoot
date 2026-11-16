import CoreGraphics
import Foundation
import ImageIO

/// The Canon orange date stamp. The glyphs are coverage masks averaged from crops of the 10
/// reference stamps (`StampFill.png`, and `StampOutline.png`, the fill dilated by 5% of the
/// glyph height). Geometry and colours are measured on the same references. The stamp is drawn
/// upright in the photo's display orientation, sized from the displayed height, so portrait
/// photos get a horizontal stamp at the bottom right.
enum DateStamp {
    private static let glyphHeightFraction: CGFloat = 0.0286
    private static let pitchPerGlyphHeight: CGFloat = 0.663
    private static let rightEdgeFraction: CGFloat = 0.932
    private static let digitBottomFraction: CGFloat = 0.872
    private static let fill = CGColor(srgbRed: 251 / 255, green: 162 / 255, blue: 3 / 255, alpha: 1)
    private static let outline = CGColor(srgbRed: 11 / 255, green: 1 / 255, blue: 0, alpha: 1)

    /// Atlas layout: one cell per character in `characters`, each `cellWidth` x `cellHeight`
    /// pixels, with the glyph's fill spanning `glyphPixels` rows starting `margin` rows down,
    /// horizontally centred in the cell.
    private static let characters = Array("0123456789/:")
    private static let cellWidth = 112
    private static let cellHeight = 152
    private static let glyphPixels: CGFloat = 120
    private static let margin: CGFloat = 16

    private static let fillMasks = masks(named: "StampFill")
    private static let outlineMasks = masks(named: "StampOutline")

    static func text(date: Date, includeTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = includeTime ? "yyyy/MM/dd HH:mm" : "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    /// `context` holds the sensor-oriented image; `orientation` is its EXIF orientation.
    static func draw(in context: CGContext, date: Date, includeTime: Bool, orientation: Int) {
        guard let fillMasks, let outlineMasks else { return }
        let sensorWidth = CGFloat(context.width)
        let sensorHeight = CGFloat(context.height)
        let swapped = orientation == 6 || orientation == 8
        let width = swapped ? sensorHeight : sensorWidth
        let height = swapped ? sensorWidth : sensorHeight
        let glyphHeight = glyphHeightFraction * height
        let pitch = pitchPerGlyphHeight * glyphHeight
        let scale = glyphHeight / glyphPixels
        let text = Array(text(date: date, includeTime: includeTime))
        let left = rightEdgeFraction * width - pitch * CGFloat(text.count)
        let bottom = height * (1 - digitBottomFraction)
        var cells: [(CGRect, Int)] = []
        for (position, character) in text.enumerated() {
            guard let index = characters.firstIndex(of: character) else { continue }
            let centre = left + pitch * (CGFloat(position) + 0.5)
            let rect = CGRect(
                x: centre - CGFloat(cellWidth) * scale / 2,
                y: bottom - (CGFloat(cellHeight) - margin - glyphPixels) * scale,
                width: CGFloat(cellWidth) * scale,
                height: CGFloat(cellHeight) * scale
            )
            cells.append((rect, index))
        }
        context.saveGState()
        context.concatenate(displayToSensor(orientation: orientation, sensorWidth: sensorWidth, sensorHeight: sensorHeight))
        context.interpolationQuality = .high
        for (masks, colour) in [(outlineMasks, outline), (fillMasks, fill)] {
            for (rect, index) in cells {
                context.saveGState()
                context.clip(to: rect, mask: masks[index])
                context.setFillColor(colour)
                context.fill(rect)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    /// Splits a bundled atlas into one DeviceGray image per character; white paints.
    private static func masks(named name: String) -> [CGImage]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let gray = CGContext(
                  data: nil, width: atlas.width, height: atlas.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        gray.draw(atlas, in: CGRect(x: 0, y: 0, width: atlas.width, height: atlas.height))
        guard let grayAtlas = gray.makeImage() else { return nil }
        let masks = characters.indices.compactMap { index in
            grayAtlas.cropping(to: CGRect(x: index * cellWidth, y: 0, width: cellWidth, height: cellHeight))
        }
        return masks.count == characters.count ? masks : nil
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
