import CoreGraphics
import Foundation
import Observation
import UIKit

enum FlashMode: String, CaseIterable {
    case auto, on, off

    var next: FlashMode {
        switch self {
        case .auto: .on
        case .on: .off
        case .off: .auto
        }
    }
}

enum DateStampMode: String, CaseIterable {
    case off, date, dateTime
}

enum CameraState {
    case starting
    case live
    case capturing
    case review(UIImage)
    case denied
    case noCamera
    case error(String)

    var isLive: Bool { if case .live = self { true } else { false } }
}

/// Settings the capture queues read; copied under a lock because they change on the main thread.
struct CaptureSettings {
    var camera: Camera = .canonA3400
    var zoom: Float = 0
    var flash: FlashMode = .auto
    var dateStamp: DateStampMode = .date
    var clockOffsetSeconds: Double = 0
    var facebookCopy = false

    var cameraClockDate: Date { Date().addingTimeInterval(clockOffsetSeconds) }
}

@MainActor
@Observable
final class CameraModel {
    private static let defaults = UserDefaults.standard

    var camera: Camera {
        didSet {
            Self.defaults.set(Int(camera.rawValue), forKey: "camera")
            if camera != oldValue { zoom = 0 }
            publishSettings()
        }
    }
    var zoom: Float = 0 {
        didSet {
            zoomBarVisibleUntil = Date().addingTimeInterval(1.5)
            publishSettings()
        }
    }
    var flash: FlashMode = .auto { didSet { publishSettings() } }
    var dateStamp: DateStampMode {
        didSet {
            Self.defaults.set(dateStamp.rawValue, forKey: "dateStamp")
            publishSettings()
        }
    }
    var clockOffsetSeconds: Double {
        didSet {
            Self.defaults.set(clockOffsetSeconds, forKey: "clockOffsetSeconds")
            publishSettings()
        }
    }
    var facebookCopy: Bool {
        didSet {
            Self.defaults.set(facebookCopy, forKey: "facebookCopy")
            publishSettings()
        }
    }
    var state: CameraState = .starting
    var previewImage: CGImage?
    var zoomBarVisibleUntil = Date.distantPast

    @ObservationIgnored let capture = CaptureService()

    var cameraClockDate: Date { Date().addingTimeInterval(clockOffsetSeconds) }

    init() {
        let defaults = Self.defaults
        camera = Camera(rawValue: UInt32(defaults.integer(forKey: "camera"))) ?? .canonA3400
        dateStamp = DateStampMode(rawValue: defaults.string(forKey: "dateStamp") ?? "") ?? .date
        clockOffsetSeconds = defaults.double(forKey: "clockOffsetSeconds")
        facebookCopy = defaults.bool(forKey: "facebookCopy")
        capture.model = self
        publishSettings()
    }

    private func publishSettings() {
        capture.update(settings: CaptureSettings(
            camera: camera,
            zoom: zoom,
            flash: flash,
            dateStamp: dateStamp,
            clockOffsetSeconds: clockOffsetSeconds,
            facebookCopy: facebookCopy
        ))
    }

    func shutter() {
        guard state.isLive else { return }
        state = .capturing
        capture.capturePhoto()
    }
}
