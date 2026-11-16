import Foundation
import ImageIO
import OvershootCore

/// EXIF the emulated camera would have written. No GPS and no Apple maker notes.
enum PhotoMetadata {
    static func properties(
        camera: Camera,
        result: overshoot_result,
        orientation: Int,
        date: Date,
        flashMode: FlashMode,
        flashFired: Bool
    ) -> [CFString: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let timestamp = formatter.string(from: date)
        let flash: Int = switch (flashMode, flashFired) {
        case (.auto, true): 0x19
        case (.auto, false): 0x18
        case (.on, _): 0x09
        case (.off, _): 0x10
        }
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: camera.make,
            kCGImagePropertyTIFFModel: camera.model,
            kCGImagePropertyTIFFDateTime: timestamp,
        ]
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: timestamp,
            kCGImagePropertyExifDateTimeDigitized: timestamp,
            kCGImagePropertyExifExposureTime: Double(result.exposure_time_s),
            kCGImagePropertyExifFNumber: Double(result.aperture),
            kCGImagePropertyExifISOSpeedRatings: [Int(result.iso)],
            kCGImagePropertyExifFocalLength: Double(result.focal_length_mm),
            kCGImagePropertyExifFocalLenIn35mmFilm: Int(result.focal_length_35mm.rounded()),
            kCGImagePropertyExifFlash: flash,
            kCGImagePropertyExifExposureProgram: 2,
            kCGImagePropertyExifMeteringMode: 5,
            kCGImagePropertyExifWhiteBalance: 0,
            kCGImagePropertyExifColorSpace: 1,
            kCGImagePropertyExifPixelXDimension: Int(result.output_width),
            kCGImagePropertyExifPixelYDimension: Int(result.output_height),
        ]
        return [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: exif,
        ]
    }
}
