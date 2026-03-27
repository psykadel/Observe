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
    @Published private(set) var recencyTier: FeedRecencyTier = .empty
    @Published private(set) var recoveryPhase: FeedRecoveryPhase = .idle

    var onConstrainedSignal: ((String) -> Void)?
    var onSnapshotResult: ((String, SnapshotRequestResult) -> Void)?

    private let accessory: HMAccessory
    private(set) var liveStartRequestedAt: Date?

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

    var isStartingLive: Bool {
        state == .starting || profile.streamControl?.streamState == .starting
    }

    var displayAspectRatio: CGFloat {
        let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        return max(0.75, min(safeAspectRatio, 2.2))
    }

    var isVisibleOnWall: Bool {
        isReachable
    }

    func status(at date: Date) -> CameraStatusSnapshot {
        if !isReachable || state == .offline {
            return CameraStatusSnapshot(
                label: "Offline",
                recencyTier: .empty,
                recoveryPhase: .idle,
                indicator: .neutral
            )
        }

        switch recencyTier {
        case .live:
            return CameraStatusSnapshot(
                label: "Live",
                recencyTier: .live,
                recoveryPhase: .idle,
                indicator: .green
            )
        case .recentSnapshot:
            return CameraStatusSnapshot(
                label: recentSnapshotLabel(at: date),
                recencyTier: .recentSnapshot,
                recoveryPhase: .idle,
                indicator: .yellow
            )
        case .staleSnapshot:
            let label = recoveryPhase == .liveRecovery ? "Reconnecting" : "Refreshing"
            return CameraStatusSnapshot(
                label: label,
                recencyTier: .staleSnapshot,
                recoveryPhase: recoveryPhase,
                indicator: .red
            )
        case .empty:
            let label: String
            switch recoveryPhase {
            case .liveRecovery:
                label = "Reconnecting"
            case .snapshotRecovery:
                label = "Refreshing"
            case .idle:
                switch state {
                case .starting:
                    label = "Connecting"
                case .failed(let message):
                    label = message
                default:
                    label = "Loading"
                }
            }

            return CameraStatusSnapshot(
                label: label,
                recencyTier: .empty,
                recoveryPhase: recoveryPhase,
                indicator: recoveryPhase == .idle ? .neutral : .red
            )
        }
    }

    func refreshMetadata() {
        name = profileIndex == 0 ? accessory.name : "\(accessory.name) \(profileIndex + 1)"
        roomName = accessory.room?.name
        isReachable = accessory.isReachable
    }

    func updatePlanningStatus(recencyTier: FeedRecencyTier, recoveryPhase: FeedRecoveryPhase) {
        self.recencyTier = recencyTier
        self.recoveryPhase = recoveryPhase
    }

    func currentRecencyTier(at date: Date) -> FeedRecencyTier {
        if isStreaming {
            return .live
        }

        guard let lastSnapshotDate else {
            return .empty
        }

        let age = max(0, date.timeIntervalSince(lastSnapshotDate))
        return age <= CameraSchedulingDefaults.staleSnapshotThreshold ? .recentSnapshot : .staleSnapshot
    }

    func preferLive(at date: Date) {
        guard isReachable else {
            state = .offline
            liveStartRequestedAt = nil
            return
        }

        if let stream = profile.streamControl?.cameraStream {
            updateCameraSource(stream)
            state = .live
            liveStartRequestedAt = nil
            return
        }

        switch profile.streamControl?.streamState {
        case .starting:
            state = .starting
            if liveStartRequestedAt == nil {
                liveStartRequestedAt = date
            }
        case .streaming:
            updateCameraSource(profile.streamControl?.cameraStream)
            state = .live
            liveStartRequestedAt = nil
        default:
            if let liveStartRequestedAt,
               date.timeIntervalSince(liveStartRequestedAt) < CameraSchedulingDefaults.liveRecoveryRetryCooldown {
                state = .starting
                return
            }
            state = .starting
            liveStartRequestedAt = date
            profile.streamControl?.startStream()
        }
    }

    func presentSnapshotIfAvailable() {
        if let snapshot = profile.snapshotControl?.mostRecentSnapshot {
            updateCameraSource(snapshot)
            lastSnapshotDate = snapshot.captureDate
            recencyTier = currentRecencyTier(at: Date())
            if recencyTier == .recentSnapshot {
                recoveryPhase = .idle
            }
            if state != .offline {
                state = .snapshot
            }
        } else if !isReachable {
            state = .offline
            cameraSource = nil
            recencyTier = .empty
            recoveryPhase = .idle
        } else if state == .idle {
            state = .starting
        }
    }

    @discardableResult
    func requestSnapshot() -> Bool {
        guard isReachable else {
            state = .offline
            cameraSource = nil
            recencyTier = .empty
            recoveryPhase = .idle
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
        liveStartRequestedAt = nil
    }

    func markOfflineIfNeeded() {
        isReachable = accessory.isReachable
        if !isReachable {
            state = .offline
            cameraSource = nil
            liveStartRequestedAt = nil
            recencyTier = .empty
            recoveryPhase = .idle
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

    private func recentSnapshotLabel(at date: Date) -> String {
        guard let lastSnapshotDate else { return "Loading" }
        let age = max(0, Int(date.timeIntervalSince(lastSnapshotDate)))
        if age >= 60 {
            return "Recent (\(age / 60)m)"
        }
        return "Recent (\(age)s)"
    }
}

extension CameraFeedCoordinator: HMCameraStreamControlDelegate {
    nonisolated func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateCameraSource(cameraStreamControl.cameraStream)
            self.state = .live
            self.lastErrorMessage = nil
            self.liveStartRequestedAt = nil
            self.recencyTier = .live
            self.recoveryPhase = .idle
        }
    }

    nonisolated func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.liveStartRequestedAt = nil

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
                self.recencyTier = self.currentRecencyTier(at: Date())
                if self.recencyTier == .recentSnapshot {
                    self.recoveryPhase = .idle
                }
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
                self.recencyTier = self.currentRecencyTier(at: Date())
                if self.recencyTier == .recentSnapshot {
                    self.recoveryPhase = .idle
                }
                if self.state != .live {
                    self.state = .snapshot
                }
            }
        }
    }
}
