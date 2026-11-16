import CoreGraphics
import Foundation
import ImageIO
import OvershootCore
import UniformTypeIdentifiers
import os

/// Development aid, on only when the app is launched with `-dumpcapture`. Each capture writes to
/// the app's Documents: the linear staging input (`.f16`), the `overshoot-cli render` arguments
/// that reproduce it (`.args`), the saved JPEG and the last viewfinder frame (`-preview.png`).
/// Pull them with `xcrun devicectl device copy from --domain-type appDataContainer`.
enum CaptureDump {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-dumpcapture")
    private static let lastPreview = OSAllocatedUnfairLock<CGImage?>(initialState: nil)

    static func record(preview: CGImage) {
        guard isEnabled else { return }
        lastPreview.withLock { $0 = preview }
    }

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// A normal launch deletes earlier dumps, about 100 MB per capture.
    static func removeOldDumpsUnlessEnabled() {
        guard !isEnabled else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("capture-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Call before processing: the pipeline reuses the staging memory. Returns the file stem.
    static func writeInput(staging: UnsafeMutableRawPointer, width: Int, height: Int, frame: overshoot_frame) -> String? {
        guard isEnabled else { return nil }
        let name = "capture-\(Int(Date().timeIntervalSince1970))"
        let camera = frame.camera == Camera.canonA3400.rawValue ? "canon" : "nikon"
        var arguments = [
            "--camera", camera, "--width", "\(width)", "--height", "\(height)",
            "--zoom", "\(frame.zoom)", "--focal-length-35mm-capture", "\(frame.focal_length_35mm_capture)",
            "--temperature", "\(frame.temperature_k)", "--seed", "\(frame.seed)",
        ]
        if frame.metadata_valid != 0 {
            arguments += ["--exposure-time", "\(frame.exposure_time_s)", "--iso", "\(frame.iso)", "--aperture", "\(frame.aperture)"]
        }
        if frame.flash_fired != 0 { arguments.append("--flash") }
        do {
            try Data(bytes: staging, count: width * height * 8).write(to: documents.appendingPathComponent("\(name).f16"))
            try arguments.joined(separator: " ").write(to: documents.appendingPathComponent("\(name).args"), atomically: true, encoding: .utf8)
            if let preview = lastPreview.withLock({ $0 }),
               let destination = CGImageDestinationCreateWithURL(
                   documents.appendingPathComponent("\(name)-preview.png") as CFURL, UTType.png.identifier as CFString, 1, nil
               ) {
                CGImageDestinationAddImage(destination, preview, nil)
                CGImageDestinationFinalize(destination)
            }
        } catch {
            Logger.capture.error("capture dump failed: \(error.localizedDescription)")
        }
        return name
    }

    static func writeOutput(name: String?, jpeg: Data) {
        guard let name else { return }
        do {
            try jpeg.write(to: documents.appendingPathComponent("\(name).jpg"))
        } catch {
            Logger.capture.error("capture dump failed: \(error.localizedDescription)")
        }
    }
}
