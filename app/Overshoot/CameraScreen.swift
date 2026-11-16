import AVKit
import SwiftUI
import UIKit

/// Portrait: status row, 3:4 viewfinder, soft-key row. Landscape: status column, 4:3
/// viewfinder, soft-key column. The menu opens over the viewfinder; the gallery covers the screen.
struct CameraScreen: View {
    @Environment(CameraModel.self) private var model
    @State private var menuOpen = false
    @State private var galleryOpen = false
    @State private var previewRotation = Angle.zero

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            Group {
                if landscape {
                    HStack(spacing: 0) {
                        StatusBar(vertical: true)
                        Viewfinder(previewRotation: previewRotation)
                            .frame(width: geometry.size.height * 4 / 3, height: geometry.size.height)
                        SoftKeyBar(vertical: true, openGallery: openGallery, openMenu: openMenu)
                    }
                } else {
                    VStack(spacing: 0) {
                        StatusBar(vertical: false).frame(height: 48)
                        Viewfinder(previewRotation: previewRotation)
                            .frame(width: geometry.size.width, height: geometry.size.width * 4 / 3)
                        SoftKeyBar(vertical: false, openGallery: openGallery, openMenu: openMenu)
                    }
                }
            }
            .overlay {
                if menuOpen {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { menuOpen = false }
                        MenuPanel { menuOpen = false }
                            .frame(maxWidth: 440)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                    }
                }
            }
            .onChange(of: landscape, initial: true) { updateRotation() }
        }
        .background(Color.black.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // The scene reports its new orientation after the notification.
            DispatchQueue.main.async { updateRotation() }
        }
        // Serves the Camera Control and the volume buttons.
        .onCameraCaptureEvent { event in
            if event.phase == .ended, !menuOpen, !galleryOpen { model.shutter() }
        }
        .fullScreenCover(isPresented: $galleryOpen) {
            GalleryScreen { galleryOpen = false }
                .environment(model)
        }
        .task { await model.loadLastThumbnail() }
    }

    private func openGallery() { galleryOpen = true }
    private func openMenu() { menuOpen = true }

    /// The preview arrives in the device's portrait orientation; a landscape layout turns it
    /// against the interface rotation so the scene stays upright.
    private func updateRotation() {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        previewRotation = switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeRight: .degrees(-90)
        case .landscapeLeft: .degrees(90)
        default: .zero
        }
    }
}
