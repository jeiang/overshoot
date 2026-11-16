import SwiftUI

/// The live picture, the review image and status messages, with the AF frame and the zoom bar.
/// `previewRotation` turns the device-oriented portrait preview upright in a landscape layout.
struct Viewfinder: View {
    @Environment(CameraModel.self) private var model
    let previewRotation: Angle
    @State private var pinchStartZoom: Float?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                content(size: geometry.size)
                if model.state.isLive || isCapturing {
                    AFFrame(locked: isCapturing)
                }
                if isCapturing {
                    Image(systemName: "hourglass")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 0, x: 1, y: 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .trailing) {
                if model.state.isLive { ZoomBar(height: min(180, geometry.size.height * 0.6)) }
            }
            .gesture(pinch)
        }
        .clipped()
    }

    private var isCapturing: Bool { if case .capturing = model.state { true } else { false } }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? model.zoom
                pinchStartZoom = start
                let delta = Float(log(value.magnification)) / logf(model.camera.zoomRatio)
                model.zoom = min(1, max(0, start + delta))
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    @ViewBuilder private func content(size: CGSize) -> some View {
        switch model.state {
        case .review(let image):
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
        case .starting:
            ProgressView().tint(Theme.orange)
        case .denied:
            message("Allow camera access in Settings to use Overshoot.")
        case .noCamera:
            message("No camera on this device.")
        case .error(let text):
            message(text)
        case .live, .capturing:
            if let image = model.previewImage {
                let turned = previewRotation != .zero
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: turned ? size.height : size.width, height: turned ? size.width : size.height)
                    .rotationEffect(previewRotation)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(17))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(24)
    }
}

/// Four corner brackets; green once the shutter is pressed, as on the Cyber-shot phones.
private struct AFFrame: View {
    let locked: Bool

    var body: some View {
        let size: CGFloat = 76
        let arm: CGFloat = 16
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
        .stroke(locked ? Color.green : .white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .shadow(color: .black.opacity(0.6), radius: 0, x: 1, y: 1)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Vertical zoom bar on the viewfinder's right edge: T at the top, W at the bottom. Drag along
/// it to zoom; it fades in while zooming.
private struct ZoomBar: View {
    @Environment(CameraModel.self) private var model
    let height: CGFloat
    @State private var lastDelta: Float = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let visible = timeline.date < model.zoomBarVisibleUntil
            VStack(spacing: 6) {
                Text("T")
                ZStack(alignment: .bottom) {
                    Capsule().fill(.black.opacity(0.45)).frame(width: 8)
                    Capsule().stroke(.white.opacity(0.8), lineWidth: 1).frame(width: 8)
                    Capsule().fill(Theme.highlight)
                        .frame(width: 8, height: max(8, CGFloat(model.zoom) * height))
                }
                .frame(height: height)
                Text("W")
                Text(String(format: "%.1fx", powf(model.camera.zoomRatio, model.zoom)))
                    .monospacedDigit()
            }
            .font(Theme.font(12))
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 0, x: 1, y: 1)
            .opacity(visible ? 1 : 0.35)
            .animation(.easeOut(duration: 0.2), value: visible)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(drag)
            .accessibilityElement()
            .accessibilityLabel("Zoom")
            .accessibilityValue(String(format: "%.1f times", powf(model.camera.zoomRatio, model.zoom)))
            .accessibilityAdjustableAction { direction in
                let step: Float = direction == .increment ? 0.1 : -0.1
                model.zoom = min(1, max(0, model.zoom + step))
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // Moving up by the bar's height spans the whole zoom range.
                let delta = Float(-value.translation.height / height)
                model.zoom = min(1, max(0, model.zoom + delta - lastDelta))
                lastDelta = delta
            }
            .onEnded { _ in lastDelta = 0 }
    }
}
