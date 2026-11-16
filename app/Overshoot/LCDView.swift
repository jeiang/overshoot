import SwiftUI

struct LCDView: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        ZStack {
            Color.black
            content
            if model.state.isLive {
                OSDOverlay()
            }
            if case .capturing = model.state {
                Image(systemName: "hourglass")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 0, x: 1, y: 1)
            }
        }
        .clipped()
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .review(let image):
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
        case .starting:
            message("…")
        case .denied:
            message("Camera access denied. Enable it in Settings.")
        case .noCamera:
            message("NO CAMERA")
        case .error(let text):
            message(text)
        case .live, .capturing:
            if let image = model.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fit)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
    }
}
