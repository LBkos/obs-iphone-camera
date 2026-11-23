import SwiftUI

@main
struct OBSCameraApp: App {
    @StateObject private var viewModel = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
