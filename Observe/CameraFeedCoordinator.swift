import Foundation
import HomeKit

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
    @Published private(set) var batteryPercentage: Int?
    @Published private var sessionImageFreshness = CameraSessionImageFreshness()

    var onSnapshotResult: ((String, SnapshotRequestID?, SnapshotRequestResult) -> Void)?
    var onLiveTransportEvent: ((String, CameraLiveTransportEvent) -> Void)?
    var onAvailabilityChanged: ((String) -> Void)?

    private let accessory: HMAccessory
    private var liveTransportState = CameraLiveTransportState.idle
    private var configuredStaleThreshold: TimeInterval = CameraSchedulingDefaults.staleVisualHighlightThreshold
    private var configuredBatteryTrustedStillThreshold: TimeInterval = CameraSchedulingDefaults.batteryWakeTriggerThreshold
    private var configuredBatteryCaptureWarmup: TimeInterval = CameraSchedulingDefaults.batteryCaptureWarmup
    private var pendingSnapshotRequestID: SnapshotRequestID?

    var liveStartRequestedAt: Date? {
        liveTransportState.startRequestedAt
    }

    var liveStartedAt: Date? {
        liveTransportState.startedAt
    }

    var liveStopRequestedAt: Date? {
        liveTransportState.stopRequestedAt
    }

    var liveStopReason: CameraLiveStopReason? {
        liveTransportState.stopReason
    }

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
        CameraLivePresentationPolicy.isLive(
            transportPhase: liveTransportState.phase,
            hasVideoSource: hasVideoSource
        )
    }

    var isStartingLive: Bool {
        liveTransportState.phase == .starting
    }

    var hasActiveLiveTransport: Bool {
        liveTransportState.phase.reservesCapacity
    }

    var liveTransportPhase: LiveTransportPhase {
        liveTransportState.phase
    }

    private var hasVideoSource: Bool {
        cameraSource is HMCameraStream
    }

    var hasFreshImageThisSession: Bool {
        sessionImageFreshness.hasFreshImage
    }

    var displayAspectRatio: CGFloat {
        let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        return max(0.75, min(safeAspectRatio, 2.2))
    }

    var isVisibleOnWall: Bool {
        CameraWallAvailability.isVisibleOnWall(
            isReachable: isReachable,
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
        refreshBatteryPercentage()
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

    func readBatteryPercentage() {
        batteryPercentageCharacteristics.forEach { characteristic in
            if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
               !characteristic.isNotificationEnabled {
                characteristic.enableNotification(true) { _ in }
            }

            characteristic.readValue { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshBatteryPercentage()
                }
            }
        }
        refreshBatteryPercentage()
    }

    func refreshHomeKitCameraActiveStateIfNeeded(for characteristic: HMCharacteristic) {
        guard CameraWallAvailability.isCameraAvailabilityCharacteristic(
            characteristicType: characteristic.characteristicType
        ) else {
            return
        }

        refreshHomeKitCameraActiveState()
    }

    func refreshBatteryPercentageIfNeeded(for characteristic: HMCharacteristic) {
        guard characteristic.characteristicType == HMCharacteristicTypeBatteryLevel else { return }

        batteryPercentage = BatteryPercentageOverlayPolicy.normalizedPercentage(from: characteristic.value)
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
        sessionImageFreshness.apply(.freshSnapshotReceived)
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

    func preferLive(at date: Date) {
        guard isReachable else {
            markOffline()
            return
        }

        if profile.streamControl?.cameraStream != nil {
            _ = reconcileLiveSourceIfAvailable(at: date)
            return
        }

        switch profile.streamControl?.streamState {
        case .starting:
            state = .starting
            _ = liveTransportState.requestStart(at: date)
        case .streaming:
            _ = reconcileLiveSourceIfAvailable(at: date)
        default:
            guard liveTransportState.requestStart(at: date) else { return }
            state = .starting
            onLiveTransportEvent?(id, .startRequested(at: date, restarted: false))
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
            let shouldPresentSnapshot = CameraLivePresentationPolicy.shouldPresentSnapshot(
                transportPhase: liveTransportState.phase,
                hasVideoSource: hasVideoSource
            )
            if shouldPresentSnapshot {
                updateCameraSource(snapshot)
                sessionImageFreshness.apply(.cachedSnapshotPresented)
            }
            lastSnapshotDate = snapshot.captureDate
            recencyTier = currentRecencyTier(at: Date())
            if recencyTier == .recentSnapshot {
                recoveryPhase = .idle
            }
            if shouldPresentSnapshot, state != .offline {
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

        guard let snapshotControl = profile.snapshotControl,
              pendingSnapshotRequestID == nil else {
            return false
        }

        pendingSnapshotRequestID = requestID
        snapshotControl.takeSnapshot()
        if cameraSource == nil {
            state = .starting
        }
        return true
    }

    @discardableResult
    func stopLiveIfNeeded(reason: CameraLiveStopReason = .planned) -> Bool {
        reconcileLiveTransportStateFromHomeKit(at: Date())
        let requestedAt = Date()
        guard liveTransportState.requestStop(at: requestedAt, reason: reason) else {
            return false
        }

        onLiveTransportEvent?(id, .stopRequested(at: requestedAt, reason: reason))
        profile.streamControl?.stopStream()
        return true
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
        sessionImageFreshness.apply(.reset)
        refreshBatteryPercentage()
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
                    characteristicType: characteristic.characteristicType
                )
            }
    }

    private var cameraAvailabilitySnapshots: [CameraWallAvailability.CharacteristicSnapshot] {
        cameraAvailabilityCharacteristics.map { characteristic in
            CameraWallAvailability.CharacteristicSnapshot(
                characteristicType: characteristic.characteristicType,
                value: characteristic.value
            )
        }
    }

    private var batteryPercentageCharacteristics: [HMCharacteristic] {
        cameraAvailabilityServices
            .flatMap(\.characteristics)
            .filter { $0.characteristicType == HMCharacteristicTypeBatteryLevel }
    }

    private func refreshBatteryPercentage() {
        batteryPercentage = batteryPercentageCharacteristics
            .compactMap { BatteryPercentageOverlayPolicy.normalizedPercentage(from: $0.value) }
            .first
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
        stopLiveIfNeeded()
        isAvailableInSession = false
        state = .offline
        cameraSource = nil
        lastSnapshotDate = nil
        recencyTier = .empty
        recoveryPhase = .idle
        batteryStillDate = nil

        if wasVisibleOnWall {
            onAvailabilityChanged?(id)
        }
    }

    private func markOffline() {
        stopLiveIfNeeded()
        state = .offline
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

    private func reconcileLiveTransportStateFromHomeKit(at date: Date) {
        guard liveTransportState.phase == .idle else { return }

        switch profile.streamControl?.streamState {
        case .starting:
            _ = liveTransportState.requestStart(at: date)
        case .streaming:
            _ = reconcileLiveSourceIfAvailable(at: date)
        default:
            break
        }
    }

    @discardableResult
    func reconcileLiveSourceIfAvailable(at date: Date) -> Bool {
        guard let stream = profile.streamControl?.cameraStream else { return false }

        if liveTransportState.phase == .idle {
            _ = liveTransportState.requestStart(at: date)
        }

        let callbackLatency = liveStartRequestedAt.map {
            max(0, date.timeIntervalSince($0))
        }
        let acceptedAsActiveTransport = liveTransportState.confirmStarted(
            at: date,
            hasVideoSource: true
        )
        updateCameraSource(stream)
        sessionImageFreshness.apply(.liveStreamReceived)
        lastErrorMessage = nil

        guard liveTransportState.phase == .streaming else { return false }

        state = .live
        recencyTier = .live
        recoveryPhase = .idle
        if acceptedAsActiveTransport {
            onLiveTransportEvent?(
                id,
                .started(at: date, callbackLatency: callbackLatency)
            )
        }
        return true
    }

    private func applySnapshot(_ snapshot: HMCameraSnapshot) {
        if CameraLivePresentationPolicy.shouldPresentSnapshot(
            transportPhase: liveTransportState.phase,
            hasVideoSource: hasVideoSource
        ) {
            updateCameraSource(snapshot)
        }
        lastSnapshotDate = snapshot.captureDate
        recencyTier = currentRecencyTier(at: Date())
        if recencyTier == .recentSnapshot {
            sessionImageFreshness.apply(.freshSnapshotReceived)
            recoveryPhase = .idle
        }
        if !isStreaming, state != .offline {
            state = .snapshot
        }
    }

}
extension CameraFeedCoordinator: HMCameraStreamControlDelegate {
    nonisolated func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.reconcileLiveSourceIfAvailable(at: Date())
        }
    }

    nonisolated func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stoppedAt = Date()
            let callbackLatency = self.liveStopRequestedAt.map {
                max(0, stoppedAt.timeIntervalSince($0))
            }
            let stopReason = self.liveTransportState.confirmStopped()
            let transportError = CameraTransportError(error)
            let disposition = CameraLiveFailureDispositionPolicy.classify(
                error: transportError,
                stopReason: stopReason
            )

            if case .retryableTransport(let error) = disposition {
                self.lastErrorMessage = error.message
            } else if case .cameraFailure(let error) = disposition {
                self.lastErrorMessage = error.message
            } else {
                self.lastErrorMessage = nil
            }

            if self.state != .offline {
                self.state = .idle
            }
            self.presentSnapshotIfAvailable()
            if self.cameraSource == nil, self.state != .offline {
                switch disposition {
                case .startupTimedOut, .retryableTransport, .cameraFailure, .ended:
                    self.state = .failed("Unavailable")
                case .requestedStop, .softContention, .hardCapacity, .infrastructureUnavailable:
                    self.state = .idle
                }
            }

            self.onLiveTransportEvent?(
                self.id,
                .stopped(at: stoppedAt, disposition: disposition, callbackLatency: callbackLatency)
            )
        }
    }
}

extension CameraFeedCoordinator: HMCameraSnapshotControlDelegate {
    nonisolated func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let requestID = self.pendingSnapshotRequestID
            self.pendingSnapshotRequestID = nil

            if let snapshot {
                self.applySnapshot(snapshot)
                self.lastErrorMessage = nil
                self.onSnapshotResult?(self.id, requestID, .success(snapshot.captureDate))
            } else {
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                }
                if self.cameraSource == nil {
                    self.state = .failed("Unavailable")
                }
                self.onSnapshotResult?(self.id, requestID, .failure(CameraTransportError(error)))
            }
        }
    }

    nonisolated func cameraSnapshotControlDidUpdateMostRecentSnapshot(_ cameraSnapshotControl: HMCameraSnapshotControl) {
        Task { @MainActor [weak self] in
            guard let self, let snapshot = cameraSnapshotControl.mostRecentSnapshot else { return }
            if self.lastSnapshotDate == nil || snapshot.captureDate > self.lastSnapshotDate! {
                self.applySnapshot(snapshot)
            }
        }
    }
}
