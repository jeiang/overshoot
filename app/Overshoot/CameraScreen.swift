import AVKit
import SwiftUI

struct CameraScreen: View {
    @Environment(CameraModel.self) private var model
    @State private var menuOpen = false

    var body: some View {
        VStack(spacing: 0) {
            LCDView()
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            ButtonStrip(menuOpen: $menuOpen)
        }
        .background(Color.black.ignoresSafeArea())
        // Serves the Camera Control and the volume buttons.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { model.shutter() }
        }
        .sheet(isPresented: $menuOpen) {
            MenuScreen()
                .environment(model)
                .presentationDetents([.medium, .large])
        }
    }
}
