import Foundation
import HomeKit

struct CameraTransportError: Equatable {
    let domain: String
    let code: Int
    let message: String

    init?(_ error: (any Error)?) {
        guard let error else { return nil }
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        message = nsError.localizedDescription
    }
}

enum SnapshotRequestResult {
    case success(Date)
    case failure(CameraTransportError?)
}

enum CameraLiveTransportEvent: Equatable {
    case startRequested(at: Date, restarted: Bool)
    case started(at: Date)
    case stopped(at: Date, reason: CameraLiveStopReason)
}

enum CameraLiveStopReason: Equatable {
    case requested
    case capacityConstrained(CameraTransportError)
    case failure(CameraTransportError)
    case ended

    var error: CameraTransportError? {
        switch self {
        case .capacityConstrained(let error), .failure(let error): error
        case .requested, .ended: nil
        }
    }

    var shouldFailStartupPath: Bool {
        self != .requested
    }

    var isCapacityConstrained: Bool {
        if case .capacityConstrained = self { return true }
        return false
    }
}

enum CameraLiveStopReasonPolicy {
    private static let capacityCodes: Set<HMError.Code> = [
        .accessoryIsBusy,
        .operationTimedOut,
        .maximumObjectLimitReached,
        .noHomeHub,
        .noCompatibleHomeHub,
        .networkUnavailable,
        .communicationFailure,
        .accessoryCommunicationFailure,
        .timedOutWaitingForAccessory
    ]

    static func classify(
        error: CameraTransportError?,
        stopWasRequested: Bool
    ) -> CameraLiveStopReason {
        guard let error else { return stopWasRequested ? .requested : .ended }

        if stopWasRequested,
           error.domain == HMErrorDomain,
           error.code == HMError.Code.operationCancelled.rawValue {
            return .requested
        }

        if error.domain == HMErrorDomain,
           let code = HMError.Code(rawValue: error.code),
           capacityCodes.contains(code) {
            return .capacityConstrained(error)
        }

        return .failure(error)
    }
}

enum CameraStreamStopErrorPolicy {
    static func shouldReport(domain: String, code: Int, stopWasRequested: Bool) -> Bool {
        let error = CameraTransportError(
            NSError(domain: domain, code: code)
        )
        return CameraLiveStopReasonPolicy.classify(
            error: error,
            stopWasRequested: stopWasRequested
        ).error != nil
    }
}

typealias SnapshotRequestID = Int64

enum CameraSessionImageEvent: Equatable {
    case reset
    case cachedSnapshotPresented
    case freshSnapshotReceived
    case liveStreamReceived
}

struct CameraSessionImageFreshness: Equatable {
    private(set) var hasFreshImage = false

    mutating func apply(_ event: CameraSessionImageEvent) {
        switch event {
        case .reset:
            hasFreshImage = false
        case .cachedSnapshotPresented:
            break
        case .freshSnapshotReceived, .liveStreamReceived:
            hasFreshImage = true
        }
    }
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
    private(set) var liveStartRequestedAt: Date?
    private(set) var liveStartedAt: Date?
    private var configuredStaleThreshold: TimeInterval = CameraSchedulingDefaults.staleVisualHighlightThreshold
    private var configuredBatteryTrustedStillThreshold: TimeInterval = CameraSchedulingDefaults.batteryWakeTriggerThreshold
    private var configuredBatteryCaptureWarmup: TimeInterval = CameraSchedulingDefaults.batteryCaptureWarmup
    private var pendingSnapshotRequestID: SnapshotRequestID?
    private var requestedStreamStop = false

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
        let serviceType = characteristic.service?.serviceType ?? ""
        guard CameraWallAvailability.isCameraAvailabilityCharacteristic(
            serviceType: serviceType,
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
            sessionImageFreshness.apply(.liveStreamReceived)
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
                requestedStreamStop = true
                profile.streamControl?.stopStream()
                liveStartRequestedAt = date
                state = .starting
                onLiveTransportEvent?(id, .startRequested(at: date, restarted: true))
                profile.streamControl?.startStream()
                return
            }

            state = .starting
            if liveStartRequestedAt == nil {
                liveStartRequestedAt = date
            }
        case .streaming:
            updateCameraSource(profile.streamControl?.cameraStream)
            sessionImageFreshness.apply(.liveStreamReceived)
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
            updateCameraSource(snapshot)
            sessionImageFreshness.apply(.cachedSnapshotPresented)
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

    func stopLiveIfNeeded() {
        switch profile.streamControl?.streamState {
        case .starting, .streaming:
            requestedStreamStop = true
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
            self.sessionImageFreshness.apply(.liveStreamReceived)
            self.state = .live
            self.lastErrorMessage = nil
            self.liveStartRequestedAt = nil
            self.markLiveStartedIfNeeded(at: now)
            self.recencyTier = .live
            self.recoveryPhase = .idle
            self.onLiveTransportEvent?(self.id, .started(at: now))
        }
    }

    nonisolated func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.liveStartRequestedAt = nil
            self.liveStartedAt = nil
            let stopWasRequested = self.requestedStreamStop
            self.requestedStreamStop = false
            let transportError = CameraTransportError(error)
            let reason = CameraLiveStopReasonPolicy.classify(
                error: transportError,
                stopWasRequested: stopWasRequested
            )

            if let error = reason.error {
                self.lastErrorMessage = error.message
            }

            self.onLiveTransportEvent?(
                self.id,
                .stopped(at: Date(), reason: reason)
            )

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
            let requestID = self.pendingSnapshotRequestID
            self.pendingSnapshotRequestID = nil

            if let snapshot {
                self.updateCameraSource(snapshot)
                self.lastSnapshotDate = snapshot.captureDate
                self.recencyTier = self.currentRecencyTier(at: Date())
                if self.recencyTier == .recentSnapshot {
                    self.sessionImageFreshness.apply(.freshSnapshotReceived)
                }
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
                self.onSnapshotResult?(self.id, requestID, .failure(CameraTransportError(error)))
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
                    self.sessionImageFreshness.apply(.freshSnapshotReceived)
                }
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
