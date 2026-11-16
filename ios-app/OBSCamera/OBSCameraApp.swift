import SwiftUI
import UIKit

@main
struct OBSCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}

/// The interface follows the stream's orientation instead of the phone's
/// rotation: the preview angle is then fixed, and turning the phone never
/// changes what OBS receives.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var allowedOrientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Self.allowedOrientations }
    }
}

enum InterfaceOrientation {
    /// Landscape: charging port to the right, the camera sensor's natural orientation.
    @MainActor
    static func lock(to orientation: VideoOrientation) {
        let mask: UIInterfaceOrientationMask = orientation == .landscape ? .landscapeRight : .portrait
        AppDelegate.allowedOrientations = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}
