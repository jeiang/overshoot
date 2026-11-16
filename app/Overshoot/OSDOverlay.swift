import SwiftUI
import UIKit

/// The camera's on-screen display: white text and symbols with a 1 pt black shadow.
struct OSDOverlay: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            ZStack {
                AFFrame(capturing: isCapturing)
                VStack {
                    HStack(alignment: .top) {
                        topLeft
                        Spacer()
                        if timeline.date < model.zoomBarVisibleUntil { ZoomBar() }
                        Spacer()
                        topRight
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        bottomLeft
                        Spacer()
                        bottomRight
                    }
                }
                .padding(10)
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 0, x: 1, y: 1)
        }
    }

    private var isCapturing: Bool { if case .capturing = model.state { true } else { false } }

    @ViewBuilder private var topLeft: some View {
        HStack(spacing: 8) {
            switch model.camera {
            case .canonA3400: Badge(text: "AUTO")
            case .nikonL11:
                Image(systemName: "camera.fill").foregroundStyle(.green)
            }
            FlashIcon(mode: model.flash)
        }
    }

    @ViewBuilder private var topRight: some View {
        VStack(alignment: .trailing, spacing: 4) {
            BatteryIcon()
            if model.camera == .canonA3400 {
                Text("L")
                Text("\(shotsRemaining)")
            }
        }
    }

    @ViewBuilder private var bottomLeft: some View {
        if model.camera == .canonA3400 { Badge(text: "IS") }
    }

    @ViewBuilder private var bottomRight: some View {
        switch model.camera {
        case .canonA3400:
            if model.dateStamp != .off { Badge(text: "DATE") }
        case .nikonL11:
            HStack(spacing: 6) {
                Text("6M")
                Text("[" + String(format: "%5d", shotsRemaining) + "]")
            }
        }
    }

    private var shotsRemaining: Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let bytes = Double(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let perShot = Double(model.camera.info.file_megabytes_average) * 1e6
        return min(9999, Int(bytes / perShot))
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1.5))
    }
}

struct FlashIcon: View {
    let mode: FlashMode

    var body: some View {
        switch mode {
        case .auto:
            HStack(spacing: 0) {
                Image(systemName: "bolt.fill")
                Text("A").font(.system(size: 9, weight: .bold, design: .monospaced))
            }
        case .on: Image(systemName: "bolt.fill")
        case .off: Image(systemName: "bolt.slash.fill")
        }
    }
}

private struct BatteryIcon: View {
    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level < 0 { return "battery.100" }
        switch level {
        case 0.875...: return "battery.100"
        case 0.625...: return "battery.75"
        case 0.375...: return "battery.50"
        case 0.125...: return "battery.25"
        default: return "battery.0"
        }
    }
}

private struct AFFrame: View {
    let capturing: Bool

    var body: some View {
        let color: Color = capturing ? .green : .white
        let size: CGFloat = 70
        let arm: CGFloat = 14
        Path { path in
            for (x, y) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let cx = size / 2 * x
                let cy = size / 2 * y
                path.move(to: CGPoint(x: cx, y: cy - arm * y))
                path.addLine(to: CGPoint(x: cx, y: cy))
                path.addLine(to: CGPoint(x: cx - arm * x, y: cy))
            }
        }
        .offset(x: size / 2, y: size / 2)
        .stroke(color, lineWidth: 2)
        .frame(width: size, height: size)
    }
}

private struct ZoomBar: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text("W")
                ZStack(alignment: .leading) {
                    Rectangle().stroke(.white, lineWidth: 1).frame(width: 110, height: 6)
                    Rectangle().fill(.white).frame(width: 3, height: 10)
                        .offset(x: CGFloat(model.zoom) * 107)
                }
                Text("T")
            }
            Text(String(format: "%.1fx", factor))
        }
    }

    private var factor: Float {
        powf(model.camera.zoomRatio, model.zoom)
    }
}
