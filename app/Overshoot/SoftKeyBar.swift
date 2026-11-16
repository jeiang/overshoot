import SwiftUI

/// Handset-style keys: the gallery key with the last photo, the orange shutter key and the menu
/// soft key. A row below the viewfinder in portrait, a column beside it in landscape.
struct SoftKeyBar: View {
    @Environment(CameraModel.self) private var model
    let vertical: Bool
    let openGallery: () -> Void
    let openMenu: () -> Void

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            Button(action: openGallery) { GalleryKey(thumbnail: model.lastThumbnail) }
                .accessibilityLabel("Gallery")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { model.shutter() } label: { ShutterKey() }
                .buttonStyle(ShutterKeyStyle())
                .accessibilityLabel("Take photo")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Menu", action: openMenu)
                .buttonStyle(SoftKeyStyle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .background(BarBackground().ignoresSafeArea())
    }
}

private struct GalleryKey: View {
    let thumbnail: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.black)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.silver)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.silver, lineWidth: 1.5))
    }
}

/// The Cyber-shot capture key: a silver dome in an orange ring.
private struct ShutterKey: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.orange)
            Circle()
                .fill(LinearGradient(colors: [.white, Theme.silver, Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                .padding(6)
            Image(systemName: "camera.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(white: 0.2))
        }
        .frame(width: 78, height: 78)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }
}

private struct ShutterKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.1 : 0)
    }
}
