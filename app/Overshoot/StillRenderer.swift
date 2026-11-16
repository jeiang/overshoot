import AVFoundation
import CoreImage
import ImageIO
import OvershootCore
import Photos
import UIKit
import UniformTypeIdentifiers
import os

/// Turns one `AVCapturePhoto` into the emulated camera's JPEG and saves it. Runs on
/// `StillPipeline.queue`.
enum StillRenderer {
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ])

    static func render(
        photo: AVCapturePhoto,
        settings: CaptureSettings,
        orientation: Int,
        previewFocalLength35mm: Float
    ) -> CameraState {
        dispatchPrecondition(condition: .onQueue(StillPipeline.queue))
        guard let pipeline = StillPipeline.acquire() else { return .error("Not enough memory") }
        guard let (image, temperature) = decode(photo) else { return .error("Cannot read the photo") }
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        let staging = pipeline.staging(width: width, height: height)
        context.render(
            image,
            toBitmap: staging,
            rowBytes: width * 8,
            bounds: image.extent,
            format: .RGBAh,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        )
        let clockDate = settings.cameraClockDate
        var frame = makeFrame(photo: photo, settings: settings, temperature: temperature, previewFocalLength35mm: previewFocalLength35mm)
        let start = Date()
        let result = pipeline.process(width: width, height: height, frame: &frame)
        Logger.capture.info("still processing took \(Date().timeIntervalSince(start), format: .fixed(precision: 3)) s")
        let outputWidth = Int(result.output_width)
        let outputHeight = Int(result.output_height)
        guard let bitmap = RGBAImage.context(width: outputWidth, height: outputHeight), let data = bitmap.data else {
            return .error("Not enough memory")
        }
        data.copyMemory(from: result.output_rgba, byteCount: outputWidth * outputHeight * 4)
        if settings.camera.hasDateStamp, settings.dateStamp != .off {
            DateStamp.draw(in: bitmap, date: clockDate, includeTime: settings.dateStamp == .dateTime, orientation: orientation)
        }
        guard let cgImage = bitmap.makeImage() else { return .error("Not enough memory") }
        let properties = PhotoMetadata.properties(
            camera: settings.camera,
            result: result,
            orientation: orientation,
            date: clockDate,
            flashMode: settings.flash,
            flashFired: photo.resolvedSettings.isFlashEnabled
        )
        guard let jpeg = encodeJPEG(cgImage, quality: CGFloat(settings.camera.info.jpeg_quality), properties: properties) else {
            return .error("Cannot encode the photo")
        }
        var saves = [jpeg]
        if settings.facebookCopy, let copy = facebookCopy(of: jpeg) { saves.append(copy) }
        if let failure = save(saves, date: clockDate) { return failure }
        let display = UIImage(cgImage: cgImage, scale: 1, orientation: uiOrientation(exif: orientation))
        return .review(display)
    }

    /// Linear-light image in sensor orientation at most 4032x3024 and exactly 4:3, with the
    /// scene's white-balance temperature when known (0 otherwise).
    private static func decode(_ photo: AVCapturePhoto) -> (CIImage, Float)? {
        guard let data = photo.fileDataRepresentation() else { return nil }
        var image: CIImage
        var temperature: Float = 0
        if photo.isRawPhoto {
            guard let filter = CIRAWFilter(imageData: data, identifierHint: nil) else { return nil }
            filter.boostAmount = 0
            filter.localToneMapAmount = 0
            filter.extendedDynamicRangeAmount = 0
            filter.isGamutMappingEnabled = false
            filter.orientation = .up
            temperature = filter.neutralTemperature
            guard let output = filter.outputImage else { return nil }
            image = output
        } else {
            guard let decoded = CIImage(data: data) else { return nil }
            image = decoded
        }
        image = cropToFourThree(image)
        let scale = min(1, CGFloat(StillPipeline.stagingWidthMax) / image.extent.width,
                        CGFloat(StillPipeline.stagingHeightMax) / image.extent.height)
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0,
            ])
        }
        let integral = image.extent.integral
        let width = min(integral.width, CGFloat(StillPipeline.stagingWidthMax))
        let height = min(integral.height, CGFloat(StillPipeline.stagingHeightMax))
        image = image.transformed(by: CGAffineTransform(translationX: -integral.minX, y: -integral.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return (image, temperature)
    }

    /// The core requires the source and output aspect ratios to match; the cameras are 4:3.
    private static func cropToFourThree(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let landscape = extent.width >= extent.height
        let ratio: CGFloat = landscape ? 4.0 / 3.0 : 3.0 / 4.0
        var crop = extent
        if extent.width / extent.height > ratio {
            crop.size.width = (extent.height * ratio).rounded(.down)
            crop.origin.x += ((extent.width - crop.width) / 2).rounded(.down)
        } else {
            crop.size.height = (extent.width / ratio).rounded(.down)
            crop.origin.y += ((extent.height - crop.height) / 2).rounded(.down)
        }
        return image.cropped(to: crop)
    }

    private static func makeFrame(
        photo: AVCapturePhoto,
        settings: CaptureSettings,
        temperature: Float,
        previewFocalLength35mm: Float
    ) -> overshoot_frame {
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let exposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.floatValue
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue
        let aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.floatValue
        let focal = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.floatValue
        let valid = exposure != nil && iso != nil && aperture != nil
        return overshoot_frame(
            camera: settings.camera.rawValue,
            zoom: settings.zoom,
            metadata_valid: valid ? 1 : 0,
            exposure_time_s: exposure ?? 0,
            iso: iso ?? 0,
            aperture: aperture ?? 0,
            flash_fired: photo.resolvedSettings.isFlashEnabled ? 1 : 0,
            focal_length_35mm_capture: focal.flatMap { $0 > 0 ? $0 : nil } ?? previewFocalLength35mm,
            temperature_k: max(0, temperature.isFinite ? temperature : 0),
            seed: UInt32(truncatingIfNeeded: Int64(photo.timestamp.value))
        )
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Reproduces 2010 Facebook resizing: at most 720 px on the long side, quality 0.85, no
    /// metadata.
    private static func facebookCopy(of jpeg: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 720,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encodeJPEG(thumbnail, quality: 0.85, properties: [:])
    }

    /// Returns the error state, or nil when every photo was saved.
    private static func save(_ photos: [Data], date: Date) -> CameraState? {
        let semaphore = DispatchSemaphore(value: 0)
        var status = PHAuthorizationStatus.notDetermined
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status = $0; semaphore.signal() }
        semaphore.wait()
        guard status == .authorized || status == .limited else { return .error("Photos access denied") }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                for photo in photos {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: photo, options: nil)
                    request.creationDate = date
                }
            }
        } catch {
            Logger.capture.error("save failed: \(error.localizedDescription)")
            return .error("Cannot save the photo")
        }
        return nil
    }

    private static func uiOrientation(exif: Int) -> UIImage.Orientation {
        switch exif {
        case 6: .right
        case 3: .down
        case 8: .left
        default: .up
        }
    }
}
