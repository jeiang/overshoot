import SwiftUI

/// The camera body below the LCD: mode dial, zoom rocker, shutter, flash and menu buttons.
struct ButtonStrip: View {
    @Environment(CameraModel.self) private var model
    @Binding var menuOpen: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 18) {
            Picker("Camera", selection: $model.camera) {
                Text("CANON").tag(Camera.canonA3400)
                Text("NIKON").tag(Camera.nikonL11)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 14) {
                    ZoomRocker()
                    PlasticButton(label: "MENU") { menuOpen = true }
                }
                ShutterButton { model.shutter() }
                VStack(spacing: 14) {
                    PlasticButton(content: AnyView(FlashIcon(mode: model.flash))) {
                        model.flash = model.flash.next
                    }
                    .accessibilityLabel("Flash \(model.flash.rawValue)")
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(white: 0.20), Color(white: 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .colorScheme(.dark)
    }
}

private struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.92), Color(white: 0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(Circle().stroke(Color(white: 0.3), lineWidth: 3))
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shutter")
    }
}

private struct PlasticButton: View {
    var label: String? = nil
    var content: AnyView? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let content { content } else if let label { Text(label) }
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 64, height: 36)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().stroke(Color(white: 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Press and hold W or T: the zoom moves at 0.8 per second, updated at 30 Hz.
private struct ZoomRocker: View {
    @Environment(CameraModel.self) private var model
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            segment("W", direction: -1)
            Rectangle().fill(Color(white: 0.35)).frame(width: 1, height: 24)
            segment("T", direction: 1)
        }
        .frame(width: 96, height: 36)
        .background(Capsule().fill(Color(white: 0.16)))
        .overlay(Capsule().stroke(Color(white: 0.35), lineWidth: 1))
    }

    private func segment(_ label: String, direction: Float) -> some View {
        Text(label)
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in start(direction) }
                    .onEnded { _ in stop() }
            )
            .accessibilityLabel(direction < 0 ? "Zoom out" : "Zoom in")
    }

    private func start(_ direction: Float) {
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                model.zoom = min(1, max(0, model.zoom + direction * 0.8 / 30))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }
}
