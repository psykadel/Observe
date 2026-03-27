import Foundation
import HomeKit

enum SnapshotRequestResult {
    case success(Date)
    case failure
}

@MainActor
final class CameraFeedCoordinator: NSObject, ObservableObject, Identifiable {
    let id: String
    let accessoryID: String
    let profileIndex: Int
    let profile: HMCameraProfile

    @Published private(set) var name: String
    @Published private(set) var roomName: String?
    @Published private(set) var isReachable: Bool
    @Published private(set) var state: FeedDisplayState = .idle
    @Published private(set) var cameraSource: HMCameraSource?
    @Published private(set) var lastSnapshotDate: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var aspectRatio: CGFloat = 16 / 9

    var onConstrainedSignal: ((String) -> Void)?
    var onSnapshotResult: ((String, SnapshotRequestResult) -> Void)?

    private let accessory: HMAccessory
    private var lastSnapshotPulseAt: Date?

    init(accessory: HMAccessory, profile: HMCameraProfile, profileIndex: Int) {
        self.accessory = accessory
        self.profile = profile
        self.profileIndex = profileIndex
        self.accessoryID = accessory.uniqueIdentifier.uuidString
        self.id = "\(accessory.uniqueIdentifier.uuidString)::\(profileIndex)"
        self.name = profileIndex == 0 ? accessory.name : "\(accessory.name) \(profileIndex + 1)"
        self.roomName = accessory.room?.name
        self.isReachable = accessory.isReachable
        super.init()
        profile.streamControl?.delegate = self
        profile.snapshotControl?.delegate = self
    }

    var isStreaming: Bool {
        state == .live || profile.streamControl?.streamState == .streaming
    }

    var displayAspectRatio: CGFloat {
        let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        return max(0.75, min(safeAspectRatio, 2.2))
    }

    var isVisibleOnWall: Bool {
        isReachable
    }

    func status(at date: Date) -> CameraStatusSnapshot {
        switch state {
        case .live:
            return CameraStatusSnapshot(label: "Live", isLive: true, isFreshSnapshot: false)
        case .starting:
            return CameraStatusSnapshot(label: "Connecting", isLive: false, isFreshSnapshot: false)
        case .snapshot:
            if let lastSnapshotDate {
                let age = max(0, Int(date.timeIntervalSince(lastSnapshotDate)))
                let isRecentSnapshot = age <= 10
                let label = if isRecentSnapshot {
                    "Recent (\(age)s)"
                } else if age >= 60 {
                    "\(age / 60)m ago"
                } else {
                    "\(age)s Ago"
                }
                return CameraStatusSnapshot(label: label, isLive: false, isFreshSnapshot: isRecentSnapshot)
            }
            return CameraStatusSnapshot(label: "Updating", isLive: false, isFreshSnapshot: false)
        case .offline:
            return CameraStatusSnapshot(label: "Offline", isLive: false, isFreshSnapshot: false)
        case .failed(let message):
            return CameraStatusSnapshot(label: message, isLive: false, isFreshSnapshot: false)
        case .idle:
            return CameraStatusSnapshot(label: "Loading", isLive: false, isFreshSnapshot: false)
        }
    }

    func refreshMetadata() {
        name = profileIndex == 0 ? accessory.name : "\(accessory.name) \(profileIndex + 1)"
        roomName = accessory.room?.name
        isReachable = accessory.isReachable
    }

    func preferLive() {
        guard isReachable else {
            state = .offline
            return
        }

        if let stream = profile.streamControl?.cameraStream {
            updateCameraSource(stream)
            state = .live
            return
        }

        switch profile.streamControl?.streamState {
        case .starting:
            state = .starting
        case .streaming:
            updateCameraSource(profile.streamControl?.cameraStream)
            state = .live
        default:
            state = .starting
            profile.streamControl?.startStream()
        }
    }

    func presentSnapshotIfAvailable() {
        if let snapshot = profile.snapshotControl?.mostRecentSnapshot {
            updateCameraSource(snapshot)
            lastSnapshotDate = snapshot.captureDate
            if state != .offline {
                state = .snapshot
            }
        } else if !isReachable {
            state = .offline
            cameraSource = nil
        } else if state == .idle {
            state = .starting
        }
    }

    @discardableResult
    func requestSnapshot() -> Bool {
        guard isReachable else {
            state = .offline
            cameraSource = nil
            return false
        }

        profile.snapshotControl?.takeSnapshot()
        if cameraSource == nil {
            state = .starting
        }
        return true
    }

    func stopLiveIfNeeded() {
        switch profile.streamControl?.streamState {
        case .starting, .streaming:
            profile.streamControl?.stopStream()
        default:
            break
        }
    }

    func markOfflineIfNeeded() {
        isReachable = accessory.isReachable
        if !isReachable {
            state = .offline
            cameraSource = nil
        }
    }

    private func updateCameraSource(_ source: HMCameraSource?) {
        cameraSource = source
        guard let source else { return }

        let sourceAspectRatio = CGFloat(source.aspectRatio)
        if sourceAspectRatio.isFinite, sourceAspectRatio > 0 {
            aspectRatio = sourceAspectRatio
        }
    }
}

extension CameraFeedCoordinator: HMCameraStreamControlDelegate {
    nonisolated func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateCameraSource(cameraStreamControl.cameraStream)
            self.state = .live
            self.lastErrorMessage = nil
        }
    }

    nonisolated func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if let error = error as NSError? {
                self.lastErrorMessage = error.localizedDescription

                if let code = HMError.Code(rawValue: error.code) {
                    switch code {
                    case .accessoryIsBusy,
                         .operationTimedOut,
                         .maximumObjectLimitReached,
                         .noHomeHub,
                         .noCompatibleHomeHub,
                         .networkUnavailable,
                         .communicationFailure,
                         .accessoryCommunicationFailure,
                         .timedOutWaitingForAccessory:
                        self.onConstrainedSignal?(self.id)
                    default:
                        break
                    }
                }
            }

            self.presentSnapshotIfAvailable()
            if self.cameraSource == nil, self.state != .offline {
                self.state = .failed("Unavailable")
            }
        }
    }
}

extension CameraFeedCoordinator: HMCameraSnapshotControlDelegate {
    nonisolated func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if let snapshot {
                self.updateCameraSource(snapshot)
                self.lastSnapshotDate = snapshot.captureDate
                self.lastSnapshotPulseAt = Date()
                if self.state != .live {
                    self.state = .snapshot
                }
                self.lastErrorMessage = nil
                self.onSnapshotResult?(self.id, .success(snapshot.captureDate))
            } else {
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                }
                if self.cameraSource == nil {
                    self.state = .failed("Unavailable")
                }
                self.onSnapshotResult?(self.id, .failure)
            }
        }
    }

    nonisolated func cameraSnapshotControlDidUpdateMostRecentSnapshot(_ cameraSnapshotControl: HMCameraSnapshotControl) {
        Task { @MainActor [weak self] in
            guard let self, let snapshot = cameraSnapshotControl.mostRecentSnapshot else { return }
            if self.lastSnapshotDate == nil || snapshot.captureDate > self.lastSnapshotDate! {
                self.updateCameraSource(snapshot)
                self.lastSnapshotDate = snapshot.captureDate
                self.lastSnapshotPulseAt = Date()
                if self.state != .live {
                    self.state = .snapshot
                }
            }
        }
    }
}
