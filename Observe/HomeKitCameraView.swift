import HomeKit
import SwiftUI

enum CameraSurfaceMode {
    case wall
    case detail
}

struct HomeKitCameraView: UIViewRepresentable {
    let cameraSource: HMCameraSource?

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: HMCameraView, context: Context) {
        uiView.cameraSource = cameraSource
    }
}

struct CameraSurfaceView: View {
    let cameraSource: HMCameraSource?
    let aspectRatio: CGFloat
    let mode: CameraSurfaceMode

    var body: some View {
        GeometryReader { proxy in
            let surfaceSize = surfaceSize(in: proxy.size)

            HomeKitCameraView(cameraSource: cameraSource)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(Color.black)
        .clipped()
    }

    private func surfaceSize(in availableSize: CGSize) -> CGSize {
        guard availableSize.width > 0, availableSize.height > 0 else { return .zero }

        switch mode {
        case .wall:
            let wallAspectRatio = CGFloat(16.0 / 9.0)
            return fillSize(for: availableSize, aspectRatio: wallAspectRatio)
        case .detail:
            return fitSize(for: availableSize, aspectRatio: normalizedAspectRatio)
        }
    }

    private var normalizedAspectRatio: CGFloat {
        let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        return max(0.75, min(safeAspectRatio, 2.2))
    }

    private func fillSize(for availableSize: CGSize, aspectRatio: CGFloat) -> CGSize {
        let widthFromHeight = availableSize.height * aspectRatio
        if widthFromHeight >= availableSize.width {
            return CGSize(width: widthFromHeight, height: availableSize.height)
        }
        return CGSize(width: availableSize.width, height: availableSize.width / aspectRatio)
    }

    private func fitSize(for availableSize: CGSize, aspectRatio: CGFloat) -> CGSize {
        let widthFromHeight = availableSize.height * aspectRatio
        if widthFromHeight <= availableSize.width {
            return CGSize(width: widthFromHeight, height: availableSize.height)
        }
        return CGSize(width: availableSize.width, height: availableSize.width / aspectRatio)
    }
}
