import SwiftUI
#if targetEnvironment(macCatalyst)
import UIKit
#endif

extension View {
    func maximizeMainWindowOnLaunch(
        platform: CameraWallPlatform,
        hasRequestedMaximize: Binding<Bool>
    ) -> some View {
        modifier(MainWindowLaunchMaximizeModifier(
            platform: platform,
            hasRequestedMaximize: hasRequestedMaximize
        ))
    }
}

private struct MainWindowLaunchMaximizeModifier: ViewModifier {
    let platform: CameraWallPlatform
    @Binding var hasRequestedMaximize: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if MainWindowPresentation.shouldMaximizeOnLaunch(for: platform) {
            content.background(
                MainWindowAccessor { windowScene in
                    windowScene.configureObserveMinimumSize(for: platform)
                    guard !hasRequestedMaximize else { return }
                    hasRequestedMaximize = true
                    windowScene.maximizeForObserveLaunch()
                }
            )
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct MainWindowAccessor: UIViewRepresentable {
    let onWindowSceneAvailable: (UIWindowScene) -> Void

    func makeUIView(context _: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let windowScene = view?.window?.windowScene {
                onWindowSceneAvailable(windowScene)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context _: Context) {
        DispatchQueue.main.async { [weak uiView] in
            if let windowScene = uiView?.window?.windowScene {
                onWindowSceneAvailable(windowScene)
            }
        }
    }
}

private extension UIWindowScene {
    func configureObserveMinimumSize(for platform: CameraWallPlatform) {
        guard let minimumSize = MainWindowPresentation.minimumSize(for: platform) else { return }

        sizeRestrictions?.minimumSize = minimumSize
    }

    func maximizeForObserveLaunch() {
        let displayFrame = screen.bounds
        guard displayFrame.width > 0, displayFrame.height > 0 else { return }

        requestGeometryUpdate(.Mac(systemFrame: displayFrame)) { error in
            NSLog("Observe failed to maximize the launch window: %@", error.localizedDescription)
        }
    }
}
#endif
