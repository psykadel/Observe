import SwiftUI

struct CameraDetailView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var feed: CameraFeedCoordinator
    @ObservedObject var store: HomeKitCameraStore

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            CameraSurfaceView(cameraSource: feed.cameraSource, aspectRatio: feed.displayAspectRatio, mode: .detail)
                .ignoresSafeArea()
                .overlay {
                    if feed.cameraSource == nil {
                        ProgressView()
                            .tint(.white)
                    }
                }

            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text(feed.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let status = feed.status(at: context.date)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(status.isLive ? Color.green : (status.isFreshSnapshot ? Color.yellow : Color.white.opacity(0.4)))
                                .frame(width: 8, height: 8)

                            Text(status.label)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.88)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .statusBarHidden()
        .onAppear {
            store.focusOn(feed: feed)
        }
        .onDisappear {
            store.clearFocus()
        }
    }
}
