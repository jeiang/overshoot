import SwiftUI

@main
struct OvershootApp: App {
    @State private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(model)
                .statusBarHidden()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.capture.stop()
                StillPipeline.release()
            case .active:
                model.capture.start()
            default:
                break
            }
        }
    }
}
