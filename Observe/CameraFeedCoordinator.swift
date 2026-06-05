import Foundation
import HomeKit

enum SnapshotRequestResult {
    case success(Date)
    case failure
}

typealias SnapshotRequestID = Int64

@MainActor
final class CameraFeedCoordinator: NSObject, ObservableObject, Identifiable {
    let id: String
    let accessoryID: String
    let profileIndex: Int
    let profile: HMCameraProfile

    @Published private(set) var name: String
    @Published private(set) var roomName: String?
    @Published private(set) var isReachable: Bool
    @Published private(set) var isAvailableInSession = true
    @Published private(set) var isHomeKitCameraActive: Bool?
    @Published private(set) var state: FeedDisplayState = .idle
    @Published private(set) var cameraSource: HMCameraSource?
    @Published private(set) var lastSnapshotDate: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var aspectRatio: CGFloat = 16 / 9
    @Published private(set) var recencyTier: FeedRecencyTier = .empty
    @Published private(set) var recoveryPhase: FeedRecoveryPhase = .idle
    @Published private(set) var isBatteryWakeCamera = false
    @Published private(set) var batteryStillDate: Date?

    var onConstrainedSignal: ((String) -> Void)?
    var onSnapshotResult: ((String, SnapshotRequestID?, SnapshotRequestResult) -> Void)?
    var onAvailabilityChanged: ((String) -> Void)?

    private let accessory: HMAccessory
    private(set) var liveStartRequestedAt: Date?
    private(set) var liveStartedAt: Date?
    private var configuredStaleThreshold: TimeInterval = CameraSchedulingDefaults.staleVisualHighlightThreshold
    private var configuredBatteryTrustedStillThreshold: TimeInterval = CameraSchedulingDefaults.batteryWakeTriggerThreshold
    private var configuredBatteryCaptureWarmup: TimeInterval = CameraSchedulingDefaults.batteryCaptureWarmup
    private var pendingSnapshotRequestIDs: [SnapshotRequestID] = []

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
        CameraWallAvailability.isVisibleOnWall(
            isReachable: isReachable,
            isAvailableInSession: isAvailableInSession,
            isHomeKitCameraActive: isHomeKitCameraActive
        )
    }

    var displayedStillDate: Date? {
        if isBatteryWakeCamera {
            return batteryStillDate
        }
        return lastSnapshotDate
    }

    func status(at date: Date) -> CameraStatusSnapshot {
        CameraDisplayClassifier.classify(
            isStreaming: isStreaming,
            isBatteryCamera: isBatteryWakeCamera,
            recoveryPhase: recoveryPhase,
            liveStartedAt: liveStartedAt,
            displayedStillDate: cameraSource == nil ? nil : displayedStillDate,
            staleThreshold: configuredStaleThreshold,
            batteryTrustedStillThreshold: configuredBatteryTrustedStillThreshold,
            batteryCaptureWarmup: configuredBatteryCaptureWarmup,
            now: date
        ).status
    }

    func refreshMetadata() {
        name = profileIndex == 0 ? accessory.name : "\(accessory.name) \(profileIndex + 1)"
        roomName = accessory.room?.name
        isReachable = accessory.isReachable
        refreshHomeKitCameraActiveState()
    }

    func refreshSessionAvailabilityFromAccessory() {
        isReachable = accessory.isReachable
        refreshHomeKitCameraActiveState()
        if isHomeKitCameraActive != false {
            isAvailableInSession = true
        }
    }

    func refreshHomeKitCameraActiveState() {
        updateHomeKitCameraActiveState(from: cameraAvailabilitySnapshots)
    }

    func readHomeKitCameraActiveState() {
        cameraAvailabilityCharacteristics.forEach { characteristic in
            if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
               !characteristic.isNotificationEnabled {
                characteristic.enableNotification(true) { _ in }
            }

            characteristic.readValue { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshHomeKitCameraActiveState()
                }
            }
        }
    }

    func refreshHomeKitCameraActiveStateIfNeeded(for characteristic: HMCharacteristic) {
        let serviceType = characteristic.service?.serviceType ?? ""
        guard CameraWallAvailability.isCameraAvailabilityCharacteristic(
            serviceType: serviceType,
            characteristicType: characteristic.characteristicType
        ) else {
            return
        }

        refreshHomeKitCameraActiveState()
    }

    func setBatteryWakeEnabled(_ enabled: Bool) {
        isBatteryWakeCamera = enabled
        if !enabled {
            batteryStillDate = nil
        }
    }

    func setConfiguredStaleThreshold(_ threshold: TimeInterval) {
        configuredStaleThreshold = max(1, threshold)
    }

    func setConfiguredBatteryTrustedStillThreshold(_ threshold: TimeInterval) {
        configuredBatteryTrustedStillThreshold = max(1, threshold)
    }

    func setConfiguredBatteryCaptureWarmup(_ warmup: TimeInterval) {
        configuredBatteryCaptureWarmup = max(1, warmup)
    }

    func markBatteryStillCaptured(at date: Date) {
        guard isBatteryWakeCamera else { return }
        batteryStillDate = date
        recencyTier = .recentSnapshot

        if !isStreaming && state != .offline {
            state = .snapshot
        }
    }

    func updatePlanningStatus(recencyTier: FeedRecencyTier, recoveryPhase: FeedRecoveryPhase) {
        self.recencyTier = recencyTier
        self.recoveryPhase = recoveryPhase
    }

    func currentRecencyTier(at date: Date) -> FeedRecencyTier {
        if isStreaming {
            return .live
        }

        guard let displayedStillDate else {
            return .empty
        }

        let age = max(0, date.timeIntervalSince(displayedStillDate))
        return age <= configuredStaleThreshold ? .recentSnapshot : .staleSnapshot
    }

    func isVisuallyStale(at date: Date, threshold: TimeInterval) -> Bool {
        CameraDisplayClassifier.classify(
            isStreaming: isStreaming,
            isBatteryCamera: isBatteryWakeCamera,
            recoveryPhase: recoveryPhase,
            liveStartedAt: liveStartedAt,
            displayedStillDate: cameraSource == nil ? nil : displayedStillDate,
            staleThreshold: threshold,
            batteryTrustedStillThreshold: configuredBatteryTrustedStillThreshold,
            batteryCaptureWarmup: configuredBatteryCaptureWarmup,
            now: date
        ).isStale
    }

    func preferLive(
        at date: Date,
        liveStartTimeout: TimeInterval = CameraSchedulingDefaults.batteryWakeLiveStartTimeout
    ) {
        guard isReachable else {
            markOffline()
            return
        }

        if let stream = profile.streamControl?.cameraStream {
            updateCameraSource(stream)
            state = .live
            liveStartRequestedAt = nil
            markLiveStartedIfNeeded(at: date)
            return
        }

        switch profile.streamControl?.streamState {
        case .starting:
            if LiveStartRecoveryPolicy.shouldRestartStartingStream(
                requestedAt: liveStartRequestedAt,
                timeout: liveStartTimeout,
                now: date
            ) {
                profile.streamControl?.stopStream()
                liveStartRequestedAt = date
                state = .starting
                profile.streamControl?.startStream()
                return
            }

            state = .starting
            if liveStartRequestedAt == nil {
                liveStartRequestedAt = date
            }
        case .streaming:
            updateCameraSource(profile.streamControl?.cameraStream)
            state = .live
            liveStartRequestedAt = nil
            markLiveStartedIfNeeded(at: date)
        default:
            if let liveStartRequestedAt,
               date.timeIntervalSince(liveStartRequestedAt) < CameraSchedulingDefaults.snapshotRequestTimeout {
                state = .starting
                return
            }
            state = .starting
            liveStartRequestedAt = date
            profile.streamControl?.startStream()
        }
    }

    func presentSnapshotIfAvailable() {
        if isBatteryWakeCamera {
            if !isReachable {
                markOffline()
            } else if batteryStillDate != nil && cameraSource != nil {
                if state != .offline {
                    state = .snapshot
                }
            } else if state == .idle || state == .snapshot {
                state = .starting
            }
            return
        }

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
            markOffline()
        } else if state == .idle {
            state = .starting
        }
    }

    @discardableResult
    func requestSnapshot(requestID: SnapshotRequestID) -> Bool {
        if isBatteryWakeCamera {
            return false
        }

        guard isReachable else {
            markOffline()
            return false
        }

        profile.snapshotControl?.takeSnapshot()
        pendingSnapshotRequestIDs.append(requestID)
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
        liveStartedAt = nil
    }

    func markOfflineIfNeeded() {
        isReachable = accessory.isReachable
        if !isReachable {
            markOffline()
        }
    }

    func resetSessionState() {
        stopLiveIfNeeded()
        isReachable = accessory.isReachable
        isAvailableInSession = true
        refreshHomeKitCameraActiveState()
        cameraSource = nil
        lastSnapshotDate = nil
        lastErrorMessage = nil
        aspectRatio = 16 / 9
        recencyTier = .empty
        recoveryPhase = .idle
        batteryStillDate = nil
        state = .idle
    }

    private var cameraAvailabilityServices: [HMService] {
        var servicesByID: [String: HMService] = [:]
        (profile.services + accessory.services).forEach { service in
            servicesByID[service.uniqueIdentifier.uuidString] = service
        }
        return Array(servicesByID.values)
    }

    private var cameraAvailabilityCharacteristics: [HMCharacteristic] {
        cameraAvailabilityServices
            .flatMap(\.characteristics)
            .filter { characteristic in
                CameraWallAvailability.isCameraAvailabilityCharacteristic(
                    serviceType: characteristic.service?.serviceType ?? "",
                    characteristicType: characteristic.characteristicType
                )
            }
    }

    private var cameraAvailabilitySnapshots: [CameraWallAvailability.CharacteristicSnapshot] {
        cameraAvailabilityCharacteristics.map { characteristic in
            CameraWallAvailability.CharacteristicSnapshot(
                serviceType: characteristic.service?.serviceType ?? "",
                characteristicType: characteristic.characteristicType,
                value: characteristic.value
            )
        }
    }

    private func updateHomeKitCameraActiveState(from snapshots: [CameraWallAvailability.CharacteristicSnapshot]) {
        guard let active = CameraWallAvailability.homeKitCameraActiveState(from: snapshots) else {
            return
        }

        let wasVisibleOnWall = isVisibleOnWall
        isHomeKitCameraActive = active

        if active {
            markHomeKitOn(wasVisibleOnWall: wasVisibleOnWall)
        } else {
            markHomeKitOff(wasVisibleOnWall: wasVisibleOnWall)
        }
    }

    private func markHomeKitOff(wasVisibleOnWall: Bool? = nil) {
        let wasVisibleOnWall = wasVisibleOnWall ?? isVisibleOnWall
        isAvailableInSession = false
        state = .offline
        cameraSource = nil
        lastSnapshotDate = nil
        liveStartRequestedAt = nil
        liveStartedAt = nil
        recencyTier = .empty
        recoveryPhase = .idle
        batteryStillDate = nil

        if wasVisibleOnWall {
            onAvailabilityChanged?(id)
        }
    }

    private func markOffline() {
        state = .offline
        liveStartRequestedAt = nil
        liveStartedAt = nil
        recencyTier = .empty
        recoveryPhase = .idle
    }

    private func updateCameraSource(_ source: HMCameraSource?) {
        cameraSource = source
        guard let source else { return }

        let sourceAspectRatio = CGFloat(source.aspectRatio)
        if sourceAspectRatio.isFinite, sourceAspectRatio > 0 {
            aspectRatio = sourceAspectRatio
        }

        markHomeKitOn()
    }

    private func markHomeKitOn(wasVisibleOnWall: Bool? = nil) {
        let wasVisibleOnWall = wasVisibleOnWall ?? isVisibleOnWall
        isReachable = accessory.isReachable
        guard isHomeKitCameraActive != false else { return }

        isAvailableInSession = true
        if !wasVisibleOnWall, isVisibleOnWall {
            onAvailabilityChanged?(id)
        }
    }

    private func markLiveStartedIfNeeded(at date: Date) {
        if liveStartedAt == nil {
            liveStartedAt = date
        }
    }

}

extension CameraFeedCoordinator: HMCameraStreamControlDelegate {
    nonisolated func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            self.updateCameraSource(cameraStreamControl.cameraStream)
            self.state = .live
            self.lastErrorMessage = nil
            self.liveStartRequestedAt = nil
            self.markLiveStartedIfNeeded(at: now)
            self.recencyTier = .live
            self.recoveryPhase = .idle
        }
    }

    nonisolated func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.liveStartRequestedAt = nil
            self.liveStartedAt = nil

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
            let requestID = self.pendingSnapshotRequestIDs.isEmpty ? nil : self.pendingSnapshotRequestIDs.removeFirst()

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
                self.onSnapshotResult?(self.id, requestID, .success(snapshot.captureDate))
            } else {
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                }
                if self.cameraSource == nil {
                    self.state = .failed("Unavailable")
                }
                self.onSnapshotResult?(self.id, requestID, .failure)
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
