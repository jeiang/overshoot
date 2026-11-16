import SwiftUI
import UIKit

/// Camera status: camera switch, flash, date stamp, shots remaining and battery. A row above the
/// viewfinder in portrait, a column beside it in landscape.
struct StatusBar: View {
    @Environment(CameraModel.self) private var model
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Button {
                model.camera = model.camera == .canonA3400 ? .nikonL11 : .canonA3400
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "camera.fill").foregroundStyle(Theme.orange)
                    Text(model.camera.make.uppercased())
                }
            }
            .accessibilityLabel("Camera: \(model.camera.displayName). Tap to switch.")
            Button { model.flash = model.flash.next } label: { FlashIcon(mode: model.flash) }
                .accessibilityLabel("Flash \(model.flash.rawValue)")
            if model.camera.hasDateStamp, model.dateStamp != .off {
                Text("DATE")
                    .font(Theme.font(11))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1))
            }
            Spacer(minLength: 0)
            Text(String(shotsRemaining))
                .monospacedDigit()
                .accessibilityLabel("\(shotsRemaining) shots remaining")
            BatteryIcon()
        }
        .font(Theme.font(15))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(vertical ? .vertical : .horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BarBackground().ignoresSafeArea())
    }

    private var shotsRemaining: Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let bytes = Double(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let perShot = Double(model.camera.info.file_megabytes_average) * 1e6
        return min(9999, Int(bytes / perShot))
    }
}

struct FlashIcon: View {
    let mode: FlashMode

    var body: some View {
        switch mode {
        case .auto:
            HStack(spacing: 1) {
                Image(systemName: "bolt.fill")
                Text("A").font(Theme.font(10))
            }
        case .on: Image(systemName: "bolt.fill").foregroundStyle(Theme.orange)
        case .off: Image(systemName: "bolt.slash.fill").foregroundStyle(Theme.silver)
        }
    }
}

private struct BatteryIcon: View {
    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(level >= 0 && level < 0.125 ? Theme.warning : .white)
            .accessibilityHidden(true)
    }

    private var level: Float {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryLevel
    }

    private var symbol: String {
        switch level {
        case ..<0: "battery.100"
        case 0.875...: "battery.100"
        case 0.625...: "battery.75"
        case 0.375...: "battery.50"
        case 0.125...: "battery.25"
        default: "battery.0"
        }
    }
}
