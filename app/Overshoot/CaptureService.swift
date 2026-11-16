import AVFoundation
import CoreGraphics
import OvershootCore
import UIKit
import os

/// Owns the capture session, runs the live preview through the core pipeline, and starts still
/// captures.
final class CaptureService: NSObject {
    weak var model: CameraModel?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "co.aidanpinard.overshoot.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private let preview = PreviewPipeline()
    private let settingsLock = OSAllocatedUnfairLock(initialState: CaptureSettings())
    private let pausedLock = OSAllocatedUnfairLock(initialState: false)
    private var configured = false
    private var frameCounter: UInt32 = 0
    /// The emulated camera's auto-flash decision for the latest preview frame. Auto flash follows
    /// it instead of the iPhone's own decision, which rarely fires in rooms a compact would light.
    private let flashNeeded = OSAllocatedUnfairLock(initialState: false)
    private var pendingCapture: PendingCapture?

    private struct PendingCapture {
        let settings: CaptureSettings
        let orientation: Int
        let previewFocalLength35mm: Float
    }

    func update(settings: CaptureSettings) {
        settingsLock.withLock { $0 = settings }
    }

    private var settings: CaptureSettings { settingsLock.withLock { $0 } }

    private var paused: Bool {
        get { pausedLock.withLock { $0 } }
        set { pausedLock.withLock { $0 = newValue } }
    }

    func start() {
        sessionQueue.async { [self] in
            if !configured {
                guard configure() else { return }
                configurePhotoDimensions()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            publish(.live)
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func publish(_ state: CameraState) {
        DispatchQueue.main.async { [weak self] in self?.model?.state = state }
    }

    /// Returns false after publishing the reason the camera cannot run.
    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            publish(.noCamera)
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { granted = $0; semaphore.signal() }
        semaphore.wait()
        guard granted else {
            publish(.denied)
            return false
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            publish(.error("Cannot open the camera"))
            return false
        }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        // deliversPreviewSizedOutputBuffers throws unless automatic sizing is off first.
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoOutput.deliversPreviewSizedOutputBuffers = true
        videoOutput.setSampleBufferDelegate(self, queue: preview.queue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(photoOutput) else {
            publish(.error("Cannot configure the camera"))
            return false
        }
        session.addOutput(videoOutput)
        session.addOutput(photoOutput)
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            // Stabilization crops the field of view; the photo has none.
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
        self.device = device
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        return true
    }

    /// Runs after commitConfiguration: the preset picks the active format at commit, and the
    /// photo output rejects dimensions that format does not support.
    private func configurePhotoDimensions() {
        guard let device else { return }
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        let largest = supported.max { $0.width * $0.height < $1.width * $1.height }
        let capped = supported.first { $0.width == 4032 && $0.height == 3024 }
        if let dimensions = capped ?? largest { photoOutput.maxPhotoDimensions = dimensions }
    }

    private func focalLength35mm(_ device: AVCaptureDevice) -> Float {
        let halfAngle = Double(device.activeFormat.videoFieldOfView) / 2 * .pi / 180
        return Float(18 / tan(halfAngle))
    }

    func capturePhoto() {
        sessionQueue.async { [self] in
            guard let device else { return }
            paused = true
            let settings = self.settings
            let photoSettings: AVCapturePhotoSettings
            if let raw = photoOutput.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) {
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: raw)
            } else {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                photoSettings.photoQualityPrioritization = .speed
                photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            }
            let flash: AVCaptureDevice.FlashMode = switch settings.flash {
            case .auto: flashNeeded.withLock { $0 } ? .on : .off
            case .on: .on
            case .off: .off
            }
            if photoOutput.supportedFlashModes.contains(flash) { photoSettings.flashMode = flash }
            let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
            pendingCapture = PendingCapture(
                settings: settings,
                orientation: Self.exifOrientation(angle: angle),
                previewFocalLength35mm: focalLength35mm(device)
            )
            photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }

    static func exifOrientation(angle: CGFloat) -> Int {
        switch Int(angle.rounded()) {
        case 90: 6
        case 180: 3
        case 270: 8
        default: 1
        }
    }

    /// Called by the still renderer when the review period ends or the capture failed.
    func resumePreview() {
        paused = false
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let device, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // The core asserts matching aspect ratios; skip frames that are not 3:4 portrait.
        let aspect = Double(width) / Double(height) / (Double(PreviewPipeline.width) / Double(PreviewPipeline.height))
        guard abs(aspect - 1) < 0.009 else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let settings = self.settings
        var source = overshoot_source_bgra8(
            pixels: base.assumingMemoryBound(to: UInt8.self),
            width: UInt32(width),
            height: UInt32(height),
            row_bytes: UInt32(CVPixelBufferGetBytesPerRow(pixelBuffer))
        )
        let gains = device.deviceWhiteBalanceGains
        let temperature = device.temperatureAndTintValues(for: gains).temperature
        frameCounter &+= 1
        var frame = overshoot_frame(
            camera: settings.camera.rawValue,
            zoom: settings.zoom,
            metadata_valid: 1,
            exposure_time_s: Float(device.exposureDuration.seconds),
            iso: device.iso,
            aperture: device.lensAperture,
            flash_fired: 0,
            focal_length_35mm_capture: focalLength35mm(device),
            temperature_k: max(0, temperature),
            seed: frameCounter
        )
        let result = preview.process(&source, &frame)
        flashNeeded.withLock { $0 = result.flash_needed != 0 }
        guard let image = RGBAImage.make(result.output_rgba, width: Int(result.output_width), height: Int(result.output_height)) else { return }
        CaptureDump.record(preview: image)
        DispatchQueue.main.async { [weak self] in self?.model?.previewImage = image }
    }
}

extension CaptureService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        sessionQueue.async { [self] in
            guard let pending = pendingCapture else { return }
            pendingCapture = nil
            if let error {
                Logger.capture.error("capture failed: \(error.localizedDescription)")
                finish(.error("Capture failed"))
                return
            }
            StillPipeline.queue.async { [self] in
                let outcome = StillRenderer.render(
                    photo: photo,
                    settings: pending.settings,
                    orientation: pending.orientation,
                    previewFocalLength35mm: pending.previewFocalLength35mm
                )
                finish(outcome)
            }
        }
    }

    private func finish(_ outcome: CameraState) {
        publish(outcome)
        let delay: Double = if case .review = outcome { 2.0 } else { 2.5 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.resumePreview()
            if let model = self.model, !model.state.isLive {
                switch model.state {
                case .review, .error, .capturing: model.state = .live
                default: break
                }
            }
        }
    }
}

enum RGBAImage {
    /// Copies RGBA8 pixels into a new `CGImage`.
    static func make(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int) -> CGImage? {
        guard let context = context(width: width, height: height), let data = context.data else { return nil }
        data.copyMemory(from: pixels, byteCount: width * height * 4)
        return context.makeImage()
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }
}

extension Logger {
    static let capture = Logger(subsystem: "co.aidanpinard.overshoot", category: "capture")
}
