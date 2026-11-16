import Foundation
import OvershootCore

/// The emulated cameras. Raw values match `overshoot_camera` in `include/overshoot.h`.
enum Camera: UInt32, CaseIterable {
    case canonA3400 = 0
    case nikonL11 = 1

    /// Camera facts come only from the Zig profiles.
    var info: overshoot_camera_info { overshoot_camera_info_get(rawValue) }
    var hasDateStamp: Bool { info.has_date_stamp != 0 }
    var zoomRatio: Float { info.focal_length_35mm_tele / info.focal_length_35mm_wide }
    var make: String { String(cString: info.make) }
    var model: String { String(cString: info.model) }
    var displayName: String {
        switch self {
        case .canonA3400: "Canon PowerShot A3400 IS"
        case .nikonL11: "Nikon Coolpix L11"
        }
    }
}

/// The live viewfinder pipeline: 480x640 portrait output, created once at app start.
final class PreviewPipeline {
    static let width: UInt32 = 480
    static let height: UInt32 = 640

    let queue = DispatchQueue(label: "co.aidanpinard.overshoot.preview")
    private let pipeline: OpaquePointer

    init() {
        guard let pipeline = overshoot_preview_create(Self.width, Self.height, 2) else {
            // 3 MB failing means the device cannot run the app at all.
            fatalError("overshoot_preview_create failed")
        }
        self.pipeline = pipeline
    }

    deinit { overshoot_pipeline_destroy(pipeline) }

    /// Call on `queue` only. The result's pixels are valid until the next call.
    func process(_ source: inout overshoot_source_bgra8, _ frame: inout overshoot_frame) -> overshoot_result {
        dispatchPrecondition(condition: .onQueue(queue))
        var result = overshoot_result()
        overshoot_preview_process(pipeline, &source, &frame, &result)
        return result
    }
}

/// The full-resolution pipeline (about 450 MB). Created at the first capture and released when
/// the app goes to the background.
final class StillPipeline {
    static let queue = DispatchQueue(label: "co.aidanpinard.overshoot.still")
    private static var shared: StillPipeline?

    static let stagingWidthMax = 4032
    static let stagingHeightMax = 3024

    private let pipeline: OpaquePointer

    private init(pipeline: OpaquePointer) { self.pipeline = pipeline }

    deinit { overshoot_pipeline_destroy(pipeline) }

    /// Call on `queue` only. Returns nil when the memory is not available.
    static func acquire() -> StillPipeline? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let shared { return shared }
        guard let pipeline = overshoot_still_create(5) else { return nil }
        shared = StillPipeline(pipeline: pipeline)
        return shared
    }

    static func release() {
        queue.async { shared = nil }
    }

    func staging(width: Int, height: Int) -> UnsafeMutableRawPointer {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        return overshoot_still_staging(pipeline, UInt32(width), UInt32(height))
    }

    func process(width: Int, height: Int, frame: inout overshoot_frame) -> overshoot_result {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        var result = overshoot_result()
        overshoot_still_process(pipeline, UInt32(width), UInt32(height), &frame, &result)
        return result
    }
}
