import Foundation
import HomeKit

private struct ActiveStartupMetadataOperation {
    let descriptor: StartupMetadataOperationDescriptor
    let issuedAt: Date
}

@MainActor
final class HomeKitCameraStore: NSObject, ObservableObject {
    @Published private(set) var homes: [HomeOption] = []
    @Published private(set) var feeds: [CameraFeedCoordinator] = []
    @Published private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus
    @Published private(set) var sessionMode: SessionMode = .optimistic
    @Published private(set) var homeHubState: HMHomeHubState = .notAvailable
    @Published private(set) var selectedHomeName: String?
    @Published private(set) var isAppActive = true
    @Published private(set) var focusedFeedID: String?
    @Published private(set) var liveCapacity = 0

    let preferences: ObservePreferences

    private let homeManager = HMHomeManager()
    private let networkPathClassifier: any CameraNetworkPathClassifying
    private weak var selectedHome: HMHome?
    private var snapshotSchedulerTask: Task<Void, Never>?
    private var wifiLiveBurstHeadStartTask: Task<Void, Never>?
    private var feedScheduleStates: [String: FeedScheduleState] = [:]
    private var currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
    private var liveAdmissionController = LiveAdmissionController(
        mode: .adaptive(maxPendingStarts: 1),
        sustainableCapacity: 0
    )
    private var lastLiveAdmissionDecision: LiveAdmissionDecision?
    private var liveCapacityExpansionBlockedUntil: Date?
    private var liveCapacityIncludesUnconfirmedMemory = false
    private var startupCoverageActive = true
    private var startupLiveRampState: StartupLiveRampState?
    private var wifiLiveBurstState: WiFiLiveBurstState?
    private var lastLivePlanTelemetrySignature: String?
    private var sessionNetworkClass: CameraNetworkClass = .unknown
    private var telemetrySessionStartedAt = Date()
    private var telemetryEvents: [CameraTelemetryEvent] = []
    private var nextTelemetrySequence = 1
    private var telemetryStartupMilestones = CameraStartupTelemetryMilestones()
    private var nextSnapshotRequestID: SnapshotRequestID = 1
    private var sessionGeneration: UInt64 = 0
    private var startupMetadataMode: StartupMetadataWorkMode = .immediateParallel
    private var startupMetadataQueue: [StartupMetadataOperationDescriptor] = []
    private var activeStartupMetadataOperation: ActiveStartupMetadataOperation?
    private var initialMediaAdmissionCompleted = false

    private let snapshotRequestTimeout = CameraSchedulingDefaults.snapshotRequestTimeout
    private let startupFastLocalLiveThreshold: TimeInterval = 3
    private let maxTelemetryEvents = 400

    private let maxConcurrentSnapshotRequests = CameraSchedulingDefaults.maxConcurrentSnapshotRequests

    private var batteryCaptureWarmup: TimeInterval {
        preferences.batteryCaptureWarmupThreshold
    }

    private var batteryWakeLeaseDuration: TimeInterval {
        max(
            CameraSchedulingDefaults.batteryWakeLeaseDuration,
            batteryCaptureWarmup + CameraSchedulingDefaults.batteryCaptureLeasePadding
        )
    }

    private var batteryWakeLiveStartTimeout: TimeInterval {
        max(CameraSchedulingDefaults.batteryWakeLiveStartTimeout, batteryWakeLeaseDuration)
    }

    init(
        preferences: ObservePreferences,
        networkPathClassifier: any CameraNetworkPathClassifying = CameraNetworkPathMonitor.shared
    ) {
        self.preferences = preferences
        self.networkPathClassifier = networkPathClassifier
        self.authorizationStatus = homeManager.authorizationStatus
        super.init()
        homeManager.delegate = self
        rebuildHomesAndFeeds()
    }

    var selectedHomeID: String? { preferences.selectedHomeID }

    var priorityOrderedFeeds: [CameraFeedCoordinator] {
        let normalized = preferences.normalizedPriority(availableIDs: feeds.map(\.id))
        let feedLookup = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        return normalized.compactMap { feedLookup[$0] }
    }

    var wallFeeds: [CameraFeedCoordinator] {
        priorityOrderedFeeds.filter { isVisibleOnWall($0) }
    }

    var hasBatteryWakeCameras: Bool {
        feeds.contains { preferences.isBatteryWakeCamera(id: $0.id) }
    }

    func setAppActive(_ active: Bool) {
        let wasActive = isAppActive
        guard wasActive != active else { return }

        isAppActive = active

        if CameraSessionActivation.shouldRebuildSession(currentlyActive: wasActive, nextActive: active) {
            focusedFeedID = nil
            rebuildHomesAndFeeds()
        } else {
            deactivateSession()
        }
    }

    func selectHome(id: String) {
        preferences.selectedHomeID = id
        rebuildHomesAndFeeds()
    }

    func movePriority(from source: IndexSet, to destination: Int) {
        preferences.movePriority(from: source, to: destination, availableIDs: feeds.map(\.id))
        objectWillChange.send()
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    func focusOn(feed: CameraFeedCoordinator) {
        focusedFeedID = feed.id
        refreshPresentation(focusedFeedID: feed.id)
    }

    func clearFocus() {
        focusedFeedID = nil
        refreshPresentation(focusedFeedID: nil)
    }

    func setBatteryCameraVisibilityEnabled(_ enabled: Bool) {
        guard preferences.isBatteryCameraVisibilityEnabled != enabled else { return }

        preferences.setBatteryCameraVisibilityEnabled(enabled)
        if enabled {
            liveCapacity = max(liveCapacity, min(1, wallFeeds.count))
        } else {
            reconcileHiddenBatteryCameraWork()
        }
        objectWillChange.send()
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    func setBatteryCameraVisibilityToggleShown(_ shown: Bool) {
        let wasEnabled = preferences.isBatteryCameraVisibilityEnabled
        preferences.setBatteryCameraVisibilityToggleShown(shown)
        guard !shown, !wasEnabled else {
            objectWillChange.send()
            return
        }

        liveCapacity = max(liveCapacity, min(1, wallFeeds.count))
        objectWillChange.send()
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    func adjustDensity(with scale: CGFloat) {
        guard CameraWallInteraction.allowsDensityAdjustment(for: .current) else { return }

        preferences.adjustDensity(with: scale)
    }

    func adjustDensity(withHorizontalSwipe translationWidth: CGFloat) {
        guard CameraWallInteraction.allowsDensityAdjustment(for: .current) else { return }

        preferences.adjustDensity(withHorizontalSwipe: translationWidth)
    }

    func telemetryReportText(at now: Date = Date()) -> String {
        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        let restrictedPhase = restrictedStartupPhase(from: planningSnapshots, at: now)
        let snapshotCapacity = SnapshotAdmissionPolicy.capacity(
            states: feedScheduleStates.values.map(\.snapshotWorkState),
            activeLimit: effectiveMaxConcurrentSnapshotRequests(at: now),
            outstandingLimit: effectiveMaxOutstandingSnapshotRequests(
                from: planningSnapshots,
                at: now
            )
        )
        let liveCapacityExpansionRetryIn = liveCapacityExpansionBlockedUntil.flatMap { blockedUntil in
            blockedUntil > now ? blockedUntil.timeIntervalSince(now) : nil
        }
        return CameraTelemetryReport(
            generatedAt: now,
            sessionStartedAt: telemetrySessionStartedAt,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            authorizationStatus: authorizationLabel,
            selectedHomeName: selectedHomeName,
            homeHubState: homeHubLabel,
            sessionMode: String(describing: sessionMode),
            isAppActive: isAppActive,
            focusedFeedID: focusedFeedID,
            liveCapacity: liveCapacity,
            liveAdmissionMode: String(describing: liveAdmissionController.mode),
            liveAdmissionSustainableCapacity: liveAdmissionController.sustainableCapacity,
            liveAdmissionSoftContentionCeiling: liveAdmissionController.softContentionSessionCeiling,
            liveAdmissionPlannerCapacity: liveAdmissionController.lastPlannerCapacity,
            liveAdmissionEffectiveCapacity: liveAdmissionController.lastEffectiveCapacity,
            liveAdmissionCapacityLimitReason: liveAdmissionController.lastCapacityLimitReason,
            liveAdmissionActiveCapacityProbeFeedID: liveAdmissionController.activeCapacityProbeFeedID,
            liveAdmissionTargetIDs: lastLiveAdmissionDecision?.targetIDs ?? [],
            liveAdmissionReservedIDs: lastLiveAdmissionDecision?.reservedTransportIDs ?? [],
            liveAdmissionQueuedIDs: lastLiveAdmissionDecision?.queuedStartIDs ?? [],
            visibleFeedCount: wallFeeds.count,
            internalMaxConcurrentSnapshotRequests: maxConcurrentSnapshotRequests,
            effectiveMaxConcurrentSnapshotRequests: effectiveMaxConcurrentSnapshotRequests(at: now),
            snapshotRequestTimeout: snapshotRequestTimeout,
            untrustedSnapshotRefreshInterval: CameraSchedulingDefaults.untrustedSnapshotRefreshInterval,
            trustedSnapshotRefreshInterval: CameraSchedulingDefaults.minimumSnapshotRefreshInterval,
            batteryCaptureWarmup: batteryCaptureWarmup,
            batteryWakeTriggerThreshold: preferences.batteryWakeTriggerThreshold,
            batteryWakeLeaseDuration: batteryWakeLeaseDuration,
            batteryWakeLiveStartTimeout: batteryWakeLiveStartTimeout,
            wiredStartupLiveStartTimeout: CameraSchedulingDefaults.wiredStartupLiveStartTimeout,
            startupCoverageActive: startupCoverageActive,
            restrictedStartupPhase: restrictedPhase?.rawValue ?? "inactive",
            ordinaryLiveGateState: restrictedPhase.map {
                $0.isOrdinaryLiveGateOpen ? "open" : "waitingForAllTrusted"
            } ?? "notRestricted",
            sessionNetworkClass: sessionNetworkClass.rawValue,
            currentNetworkClass: networkPathClassifier.currentClass.rawValue,
            wifiLiveBurstMode: wifiLiveBurstModeLabel,
            wifiLiveBurstSurvivorIDs: wifiLiveBurstState?.survivingLiveIDs.sorted() ?? [],
            startupLiveRampMode: startupLiveRampState?.mode.rawValue ?? "inactive",
            startupLiveRampSelectedIDs: startupLiveRampState?.selectedIDs.sorted() ?? [],
            startupLiveRampPendingIDs: startupLiveRampState?.pendingIDs.sorted() ?? [],
            startupLiveRampMaxPendingCount: startupLiveRampState?.maxPendingCount ?? 0,
            startupLiveRampFastThreshold: startupFastLocalLiveThreshold,
            activeSnapshotRequests: snapshotCapacity.activeCount,
            outstandingSnapshotRequests: snapshotCapacity.outstandingCount,
            startupMetadataMode: startupMetadataMode.rawValue,
            startupMetadataGateState: startupMetadataGateState,
            activeMetadataOperations: activeStartupMetadataOperation == nil ? 0 : 1,
            queuedMetadataOperations: startupMetadataQueue.count,
            activeMetadataOperation: activeStartupMetadataOperation?.descriptor.telemetryLabel,
            liveCapacityExpansionRetryIn: liveCapacityExpansionRetryIn,
            liveCapacityExpansionCooldownEligible: sessionMode == .constrained
                && liveCapacityExpansionRetryIn == nil,
            liveCapacityIncludesUnconfirmedMemory: liveCapacityIncludesUnconfirmedMemory,
            startupMilestones: telemetryStartupMilestones,
            feeds: telemetryFeeds(at: now),
            events: telemetryEvents
        ).text
    }

    private func rebuildHomesAndFeeds() {
        sessionGeneration &+= 1
        let callbackGeneration = sessionGeneration
        homes = homeManager.homes
            .map { HomeOption(id: $0.uniqueIdentifier.uuidString, name: $0.name, isPrimary: $0.isPrimary) }
            .sorted {
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary && !$1.isPrimary }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        let fallbackHomeID = homes.first(where: \.isPrimary)?.id ?? homes.first?.id
        if preferences.selectedHomeID == nil {
            preferences.selectedHomeID = fallbackHomeID
        }

        let targetHomeID = preferences.selectedHomeID ?? fallbackHomeID
        let home = homeManager.homes.first { $0.uniqueIdentifier.uuidString == targetHomeID } ?? homeManager.homes.first
        selectedHome = home
        selectedHomeName = home?.name
        homeHubState = home?.homeHubState ?? .notAvailable

        feeds.forEach { $0.stopLiveIfNeeded() }

        guard let home else {
            clearMissingHomeState()
            return
        }

        home.delegate = self

        let metadataMode = StartupMetadataWorkMode.resolve(
            networkClass: networkPathClassifier.currentClass
        )
        var discoveredFeeds: [CameraFeedCoordinator] = []
        for accessory in home.accessories {
            accessory.delegate = self

            let profiles = accessory.cameraProfiles ?? []
            for (index, profile) in profiles.enumerated() {
                let feed = CameraFeedCoordinator(accessory: accessory, profile: profile, profileIndex: index)
                configureCallbacks(on: feed, generation: callbackGeneration)
                feed.refreshHomeKitCameraActiveState()
                if metadataMode == .immediateParallel {
                    feed.readHomeKitCameraActiveState()
                    feed.readBatteryPercentage()
                }
                discoveredFeeds.append(feed)
            }
        }

        let priorityIDs = preferences.normalizedPriority(availableIDs: discoveredFeeds.map(\.id))
        let feedLookup = Dictionary(uniqueKeysWithValues: discoveredFeeds.map { ($0.id, $0) })
        feeds = priorityIDs.compactMap { feedLookup[$0] }

        feedScheduleStates = Dictionary(
            uniqueKeysWithValues: feeds.map { feed in
                (
                    feed.id,
                    FeedScheduleState(
                        lastSnapshotSuccessAt: feed.lastSnapshotDate,
                        snapshotWorkState: .idle,
                        lastSnapshotRequestIssuedAt: nil,
                        lastSnapshotFailureAt: nil,
                        batteryWakeLeaseStartedAt: nil,
                        batteryWakeRetryAfter: nil,
                        consecutiveBatteryWakeFailures: 0,
                        startupState: StartupCameraState()
                    )
                )
            }
        )

        prepareDiscoveredSession()
        startSession()
    }

    private func deactivateSession() {
        sessionGeneration &+= 1
        snapshotSchedulerTask?.cancel()
        wifiLiveBurstHeadStartTask?.cancel()
        focusedFeedID = nil
        liveCapacity = 0
        liveCapacityExpansionBlockedUntil = nil
        liveCapacityIncludesUnconfirmedMemory = false
        startupCoverageActive = true
        startupLiveRampState = nil
        wifiLiveBurstState = nil
        lastLivePlanTelemetrySignature = nil
        resetStartupMetadataWork()
        currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
        liveAdmissionController = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: 1),
            sustainableCapacity: 0
        )
        lastLiveAdmissionDecision = nil
        feeds.forEach { $0.resetSessionState() }
    }

    private func clearMissingHomeState() {
        feeds = []
        feedScheduleStates = [:]
        currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
        liveAdmissionController = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: 1),
            sustainableCapacity: 0
        )
        lastLiveAdmissionDecision = nil
        liveCapacity = 0
        liveCapacityExpansionBlockedUntil = nil
        liveCapacityIncludesUnconfirmedMemory = false
        startupCoverageActive = true
        startupLiveRampState = nil
        wifiLiveBurstState = nil
        resetStartupMetadataWork()
    }

    private func configureCallbacks(on feed: CameraFeedCoordinator, generation: UInt64) {
        feed.onSnapshotResult = { [weak self] feedID, requestID, result in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsCallback(generation: generation) else { return }
                self.handleSnapshotResult(for: feedID, requestID: requestID, result: result)
            }
        }
        feed.onLiveTransportEvent = { [weak self] feedID, event in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsCallback(generation: generation) else { return }
                self.handleLiveTransportEvent(for: feedID, event: event)
            }
        }
        feed.onAvailabilityChanged = { [weak self] feedID in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsCallback(generation: generation) else { return }
                self.handleAvailabilityChange(for: feedID)
            }
        }
    }

    private func prepareDiscoveredSession() {
        sessionMode = .optimistic
        liveCapacity = wallFeeds.count
        liveAdmissionController = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: 1),
            sustainableCapacity: wallFeeds.count
        )
        lastLiveAdmissionDecision = nil
        liveCapacityExpansionBlockedUntil = nil
        liveCapacityIncludesUnconfirmedMemory = false
        startupCoverageActive = true
        startupLiveRampState = nil
        wifiLiveBurstState = nil
        lastLivePlanTelemetrySignature = nil
    }

    private func startSession() {
        snapshotSchedulerTask?.cancel()
        wifiLiveBurstHeadStartTask?.cancel()

        guard isAppActive, !feeds.isEmpty else { return }

        telemetrySessionStartedAt = Date()
        telemetryEvents = []
        nextTelemetrySequence = 1
        telemetryStartupMilestones = CameraStartupTelemetryMilestones()
        nextSnapshotRequestID = 1
        startupCoverageActive = true
        startupLiveRampState = nil
        lastLivePlanTelemetrySignature = nil
        let networkClass = networkPathClassifier.currentClass
        sessionNetworkClass = networkClass
        startupMetadataMode = StartupMetadataWorkMode.resolve(networkClass: networkClass)
        activeStartupMetadataOperation = nil
        initialMediaAdmissionCompleted = startupMetadataMode == .immediateParallel
        startupMetadataQueue = startupMetadataMode == .mediaPrioritySerial
            ? StartupMetadataAdmissionPolicy.ordered(feeds.flatMap { $0.startupMetadataOperations() })
            : []
        wifiLiveBurstState = WiFiLiveBurstState(
            networkClass: networkClass,
            visibleFeedIDs: Set(wallFeeds.map(\.id)),
            batteryFeedIDs: Set(wallFeeds.filter { preferences.isBatteryWakeCamera(id: $0.id) }.map(\.id)),
            startedAt: telemetrySessionStartedAt,
            batteryDeadline: batteryWakeLiveStartTimeout
        )
        recordTelemetry(
            "session start feeds=\(feeds.count) visible=\(wallFeeds.count) liveCapacity=\(liveCapacity) network=\(networkClass.rawValue) wifiBurst=\(wifiLiveBurstModeLabel)"
        )
        if !startupMetadataQueue.isEmpty {
            telemetryStartupMilestones.metadata.recordQueued(
                count: startupMetadataQueue.count,
                at: elapsedSinceSession(telemetrySessionStartedAt)
            )
            recordTelemetry(
                "metadata queued mode=\(startupMetadataMode.rawValue) count=\(startupMetadataQueue.count) gate=waitingForInitialMediaAdmission"
            )
            for operation in startupMetadataQueue {
                recordTelemetry(
                    "metadata queued feed=\(operation.feedID) kind=\(operation.kind.rawValue) characteristic=\(operation.characteristicType)"
                )
            }
        }
        refreshPresentation(focusedFeedID: focusedFeedID)

        if wifiLiveBurstState?.mode == .headStart {
            let generation = sessionGeneration
            wifiLiveBurstHeadStartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(WiFiLiveBurstDefaults.snapshotHeadStart))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.isAppActive,
                          self.sessionGeneration == generation else { return }
                    self.refreshPresentation(focusedFeedID: self.focusedFeedID)
                }
            }
        }

        snapshotSchedulerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    self.handleSnapshotTimeouts()
                    self.refreshPresentation(focusedFeedID: self.focusedFeedID)
                }
            }
        }
    }

    private func acceptsCallback(generation: UInt64) -> Bool {
        CameraSessionGeneration.accepts(
            callbackGeneration: generation,
            activeGeneration: sessionGeneration
        )
    }

    private func refreshPresentation(focusedFeedID: String?) {
        guard isAppActive else { return }

        configureFeedsForPresentation()
        let now = Date()
        reconcileFeedScheduleStates(at: now, focusedFeedID: focusedFeedID)

        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        updateTrustedImageMilestones(from: planningSnapshots, at: now)
        updateStartupCoverage(from: planningSnapshots, at: now)
        updateWiFiLiveBurst(from: planningSnapshots, at: now)
        updateStartupLiveRamp(from: planningSnapshots, at: now)

        let liveBudget = resolveLiveBudget(from: planningSnapshots, at: now)
        let startupLivePolicy = resolveStartupLivePolicy(from: planningSnapshots, at: now)
        currentRecoveryPlan = CameraRecoveryPlanner(
            batteryWakeLeaseDuration: batteryWakeLeaseDuration,
            batteryCaptureWarmup: batteryCaptureWarmup,
            batteryWakeLiveStartTimeout: batteryWakeLiveStartTimeout
        ).makePlan(
            feeds: planningSnapshots,
            sessionMode: sessionMode,
            liveCapacity: liveBudget,
            startupLivePolicy: startupLivePolicy,
            now: now
        )

        cancelBatteryWakeLeasesSupersededByFocus(at: now)
        let (admission, desiredLiveIDs) = reconcileLiveAdmission(
            focusedFeedID: focusedFeedID,
            liveBudget: liveBudget,
            startupLivePolicy: startupLivePolicy,
            now: now
        )
        applyRecoveryPlan(
            admission: admission,
            desiredLiveIDs: desiredLiveIDs,
            at: now
        )
        queuePlannedSnapshots(at: now)
        serviceSnapshotQueue()
        openStartupMetadataGateAfterInitialMediaAdmission(at: Date())
        serviceStartupMetadataQueue()
    }

    private var startupMetadataGateState: String {
        switch startupMetadataMode {
        case .immediateParallel:
            "immediate"
        case .mediaPrioritySerial:
            initialMediaAdmissionCompleted ? "open" : "waitingForInitialMediaAdmission"
        }
    }

    private func resetStartupMetadataWork() {
        startupMetadataMode = .immediateParallel
        startupMetadataQueue = []
        activeStartupMetadataOperation = nil
        initialMediaAdmissionCompleted = false
    }

    private func openStartupMetadataGateAfterInitialMediaAdmission(at date: Date) {
        guard startupMetadataMode == .mediaPrioritySerial,
              !initialMediaAdmissionCompleted else { return }

        initialMediaAdmissionCompleted = true
        recordTelemetry(
            "metadata gate opened after initial media admission queued=\(startupMetadataQueue.count)",
            at: date
        )
    }

    private func serviceStartupMetadataQueue() {
        let limit = StartupMetadataAdmissionPolicy.maxConcurrentOperations(
            mode: startupMetadataMode,
            initialMediaAdmissionCompleted: initialMediaAdmissionCompleted
        )
        guard limit > 0,
              activeStartupMetadataOperation == nil,
              !startupMetadataQueue.isEmpty else { return }

        let operation = startupMetadataQueue.removeFirst()
        let issuedAt = Date()
        activeStartupMetadataOperation = ActiveStartupMetadataOperation(
            descriptor: operation,
            issuedAt: issuedAt
        )
        telemetryStartupMilestones.metadata.recordIssued(
            activeCount: 1,
            at: elapsedSinceSession(issuedAt)
        )
        recordTelemetry(
            "metadata issued feed=\(operation.feedID) kind=\(operation.kind.rawValue) characteristic=\(operation.characteristicType) queueWait=\(formatPreciseSeconds(elapsedSinceSession(issuedAt))) queuedRemaining=\(startupMetadataQueue.count)",
            at: issuedAt
        )

        let generation = sessionGeneration
        let accepted = feeds.first { $0.id == operation.feedID }?.performStartupMetadataOperation(
            operation
        ) { [weak self] error in
            guard let self, self.acceptsCallback(generation: generation) else { return }
            self.completeStartupMetadataOperation(operation, error: error, at: Date())
        } ?? false

        if !accepted {
            completeStartupMetadataOperation(operation, rejectionReason: "operationRejected", at: Date())
        }
    }

    private func completeStartupMetadataOperation(
        _ operation: StartupMetadataOperationDescriptor,
        error: CameraTransportError?,
        at date: Date
    ) {
        completeStartupMetadataOperation(
            operation,
            rejectionReason: error.map(transportErrorLabel),
            at: date
        )
    }

    private func completeStartupMetadataOperation(
        _ operation: StartupMetadataOperationDescriptor,
        rejectionReason: String?,
        at date: Date
    ) {
        guard let active = activeStartupMetadataOperation,
              active.descriptor.id == operation.id else { return }

        activeStartupMetadataOperation = nil
        let callbackLatency = max(0, date.timeIntervalSince(active.issuedAt))
        telemetryStartupMilestones.metadata.recordCompleted(
            failed: rejectionReason != nil,
            callbackLatency: callbackLatency,
            at: elapsedSinceSession(date)
        )
        recordTelemetry(
            "metadata completed feed=\(operation.feedID) kind=\(operation.kind.rawValue) characteristic=\(operation.characteristicType) callbackLatency=\(formatPreciseSeconds(callbackLatency)) error=\(rejectionReason ?? "nil") queuedRemaining=\(startupMetadataQueue.count)",
            at: date
        )
        serviceStartupMetadataQueue()
    }

    private func configureFeedsForPresentation() {
        feeds.forEach { feed in
            let isBatteryCamera = preferences.isBatteryWakeCamera(id: feed.id)
            feed.setBatteryWakeEnabled(isBatteryCamera)
            feed.setConfiguredStaleThreshold(
                isBatteryCamera
                    ? preferences.batteryStaleThreshold
                    : preferences.staleVisualHighlightThreshold
            )
            feed.setConfiguredBatteryTrustedStillThreshold(preferences.batteryWakeTriggerThreshold)
            feed.setConfiguredBatteryCaptureWarmup(batteryCaptureWarmup)
        }
    }

    private func resolveLiveBudget(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) -> Int {
        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        switch sessionMode {
        case .optimistic:
            return planningSnapshots.count
        case .constrained:
            if currentLiveCount > 0 {
                recordRememberedRestrictedLiveCapacity(currentLiveCount)
            }
            if liveCapacityIncludesUnconfirmedMemory, currentLiveCount >= liveCapacity {
                liveCapacityIncludesUnconfirmedMemory = false
            }
            liveCapacity = RestrictedLiveCapacity.recordSuccessfulStreams(
                previousCapacity: liveCapacity,
                currentLiveCount: currentLiveCount,
                visibleFeedCount: planningSnapshots.count
            )
            let canProbeCapacity = liveCapacityExpansionBlockedUntil.map { now >= $0 } ?? true
            let allVisibleFeedsTrusted = !planningSnapshots.isEmpty && planningSnapshots.allSatisfy {
                $0.hasTrustedImage(at: now)
            }
            return RestrictedLiveCapacity.planningBudget(
                knownCapacity: liveCapacity,
                visibleFeedCount: planningSnapshots.count,
                allVisibleFeedsTrusted: allVisibleFeedsTrusted,
                canProbeCapacity: canProbeCapacity
            )
        }
    }

    private func resolveStartupLivePolicy(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) -> StartupLivePolicy {
        let wiredStartupFeeds = planningSnapshots.filter { !$0.isBatteryWakeCamera }
        let allWiredSnapshotPathsAttempted = wiredStartupFeeds.allSatisfy {
            $0.hasTrustedImage(at: now) || $0.startupState.snapshotAttempted
        }
        let hasActiveSnapshotRequest = feedScheduleStates.values.contains {
            $0.snapshotWorkState.isActive
        }
        if sessionMode == .optimistic,
           let wifiLiveBurstState,
           !wifiLiveBurstState.liveIDs.isEmpty {
            return .liveBurst(liveIDs: wifiLiveBurstState.liveIDs)
        } else if let restrictedStartupPhase = restrictedStartupPhase(
            from: planningSnapshots,
            at: now
        ), !restrictedStartupPhase.isOrdinaryLiveGateOpen {
            return .restrictedSnapshotOnly
        } else if sessionMode == .optimistic,
           let startupLiveRampState,
           startupLiveRampState.mode != .completed {
            return .capacityRamp(
                liveIDs: startupLiveRampState.selectedIDs,
                maxPendingStarts: startupLiveRampState.maxPendingCount
            )
        } else if sessionNetworkClass == .wifi, startupCoverageActive {
            return .wifiFallback(
                allowWiredFallback: allWiredSnapshotPathsAttempted && !hasActiveSnapshotRequest
            )
        } else {
            return .normal
        }
    }

    private func restrictedStartupPhase(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) -> RestrictedStartupPhase? {
        guard sessionNetworkClass != .wifi, !planningSnapshots.isEmpty else { return nil }

        return RestrictedStartupPhase.resolve(
            initialSnapshotPassActive: startupCoverageActive,
            allVisibleFeedsTrusted: planningSnapshots.allSatisfy { $0.hasTrustedImage(at: now) }
        )
    }

    private func reconcileLiveAdmission(
        focusedFeedID: String?,
        liveBudget: Int,
        startupLivePolicy: StartupLivePolicy,
        now: Date
    ) -> (LiveAdmissionDecision, Set<String>) {
        let desiredLiveIDs = Set(currentRecoveryPlan.decisionsByID.compactMap { id, decision in
            decision.presentationMode == .live ? id : nil
        })
        let admissionMode: LiveAdmissionMode
        if wifiLiveBurstState?.liveIDs.isEmpty == false {
            admissionMode = .wifiBurst
        } else if sessionMode == .constrained {
            admissionMode = .constrained
        } else {
            admissionMode = .adaptive(maxPendingStarts: startupLivePolicy.pendingStartLimit)
        }
        liveAdmissionController.update(mode: admissionMode, sustainableCapacity: liveCapacity)

        let visibleFeeds = wallFeeds
        let priorityByID = Dictionary(uniqueKeysWithValues: visibleFeeds.enumerated().map { ($0.element.id, $0.offset) })
        var liveIntents = visibleFeeds.compactMap { feed -> LiveIntent? in
            guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { return nil }
            let isDesired = desiredLiveIDs.contains(feed.id)
            guard isDesired || feed.liveTransportPhase == .streaming else { return nil }
            let role: LiveIntentRole
            if feed.id == focusedFeedID {
                role = .focused
            } else if decision.recoveryPhase == .batteryCapture
                        || feedScheduleStates[feed.id]?.batteryWakeLeaseStartedAt != nil {
                role = .batteryCapture
            } else if startupCoverageActive,
                      feedScheduleStates[feed.id]?.startupState.resolution != .trusted {
                role = .firstImageRecovery
            } else if liveBudget > liveCapacity, !feed.isStreaming {
                role = .capacityProbe
            } else {
                role = .steadyState
            }
            return LiveIntent(
                id: feed.id,
                role: role,
                priorityIndex: priorityByID[feed.id] ?? Int.max,
                isDesired: isDesired
            )
        }
        liveIntents.sort { lhs, rhs in
            if lhs.priorityIndex != rhs.priorityIndex { return lhs.priorityIndex < rhs.priorityIndex }
            return lhs.id < rhs.id
        }
        let transports = Dictionary(uniqueKeysWithValues: visibleFeeds.map { ($0.id, $0.liveTransportPhase) })
        let hasRecoveringCamera = feedScheduleStates.values.contains {
            $0.startupState.resolution == .recovering
        }
        let restrictedLiveGateClosed = restrictedStartupPhase(
            from: planningSnapshots(at: now, focusedFeedID: focusedFeedID),
            at: now
        ).map { !$0.isOrdinaryLiveGateOpen } ?? false
        let admission = liveAdmissionController.reconcile(
            intents: liveIntents,
            transports: transports,
            preserveActiveDuringCoverage: (startupCoverageActive || hasRecoveringCamera)
                && sessionMode == .constrained
                && !restrictedLiveGateClosed,
            plannerCapacity: liveBudget,
            now: now
        )
        lastLiveAdmissionDecision = admission
        recordLivePlanTransitionIfNeeded(
            admission,
            plannerBudget: liveBudget,
            desiredLiveIDs: desiredLiveIDs
        )
        return (admission, desiredLiveIDs)
    }

    private func applyRecoveryPlan(
        admission: LiveAdmissionDecision,
        desiredLiveIDs: Set<String>,
        at now: Date
    ) {
        for feed in feeds where isVisibleOnWall(feed) {
            guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { continue }
            feed.updatePlanningStatus(recencyTier: decision.recencyTier, recoveryPhase: decision.recoveryPhase)
            updateBatteryWakeLease(for: feed.id, decision: decision, at: now)
        }

        for feed in feeds where admission.stopIDs.contains(feed.id) {
            feed.stopLiveIfNeeded()
        }

        for feed in feeds where isVisibleOnWall(feed) && !desiredLiveIDs.contains(feed.id) {
            feed.presentSnapshotIfAvailable()
        }

        if admission.stopIDs.isEmpty {
            for feed in feeds where admission.startIDs.contains(feed.id) && isVisibleOnWall(feed) {
                feed.preferLive(at: now)
            }
        }

        for feed in feeds where desiredLiveIDs.contains(feed.id) && isVisibleOnWall(feed) {
            feed.reconcileLiveSourceIfAvailable(at: now)
            updateBatteryCaptureTrust(for: feed.id, at: now)
        }
    }

    private func queuePlannedSnapshots(at now: Date) {
        let wifiBurstOpen = wifiLiveBurstState.map { !$0.liveIDs.isEmpty } ?? false
        for feed in feeds where isVisibleOnWall(feed) {
            guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { continue }
            if LivePromotionSnapshotPolicy.shouldQueue(
                priority: decision.snapshotPriority,
                presentationMode: decision.presentationMode,
                wifiBurstOpen: wifiBurstOpen
            ), !feed.isStreaming {
                queueSnapshotRefresh(for: feed.id, priority: decision.snapshotPriority, at: now)
            } else if var state = feedScheduleStates[feed.id],
                      case .queued = state.snapshotWorkState {
                state.snapshotWorkState = .idle
                feedScheduleStates[feed.id] = state
            }
        }
    }

    private func recordLivePlanTransitionIfNeeded(
        _ admission: LiveAdmissionDecision,
        plannerBudget: Int,
        desiredLiveIDs: Set<String>
    ) {
        let signature = [
            "desired=\(desiredLiveIDs.sorted().joined(separator: ","))",
            "target=\(admission.targetIDs.joined(separator: ","))",
            "reserved=\(admission.reservedTransportIDs.joined(separator: ","))",
            "stop=\(admission.stopIDs.joined(separator: ","))",
            "start=\(admission.startIDs.joined(separator: ","))",
            "queued=\(admission.queuedStartIDs.joined(separator: ","))",
            "mode=\(String(describing: liveAdmissionController.mode))",
            "sustainable=\(liveCapacity)",
            "plannerBudget=\(plannerBudget)",
            "effectiveCapacity=\(liveAdmissionController.lastEffectiveCapacity.map(String.init) ?? "nil")",
            "capacityLimit=\(liveAdmissionController.lastCapacityLimitReason)",
            "capacityProbe=\(liveAdmissionController.activeCapacityProbeFeedID ?? "none")"
        ].joined(separator: " ")
        guard signature != lastLivePlanTelemetrySignature else { return }
        lastLivePlanTelemetrySignature = signature
        recordTelemetry("live plan \(signature)")
    }

    private func planningSnapshots(at now: Date, focusedFeedID: String?) -> [FeedPlanningSnapshot] {
        wallFeeds.enumerated().map { index, feed in
            let state = feedScheduleStates[feed.id]
            let isBatteryWakeCamera = preferences.isBatteryWakeCamera(id: feed.id)
            let lastSnapshotDate = if isBatteryWakeCamera {
                feed.displayedStillDate
            } else {
                feed.displayedStillDate ?? state?.lastSnapshotSuccessAt
            }
            return FeedPlanningSnapshot(
                id: feed.id,
                priorityIndex: index,
                isFocused: feed.id == focusedFeedID,
                isStreaming: feed.isStreaming,
                liveStartedAt: feed.liveStartedAt,
                lastSnapshotDate: lastSnapshotDate,
                staleThreshold: isBatteryWakeCamera ? preferences.batteryStaleThreshold : preferences.staleVisualHighlightThreshold,
                isBatteryWakeCamera: isBatteryWakeCamera,
                batteryWakeTriggerThreshold: preferences.batteryWakeTriggerThreshold,
                batteryWakeLeaseStartedAt: state?.batteryWakeLeaseStartedAt,
                batteryWakeRetryAfter: state?.batteryWakeRetryAfter,
                startupState: state?.startupState ?? StartupCameraState()
            )
        }
    }

    private func reconcileFeedScheduleStates(at now: Date, focusedFeedID: String?) {
        reconcileHiddenBatteryCameraWork()

        for feed in feeds {
            guard var state = feedScheduleStates[feed.id] else { continue }

            let isBatteryCamera = preferences.isBatteryWakeCamera(id: feed.id)
            let liveStartTimeout = LiveStartTimeoutPolicy.timeout(
                startupCoverageActive: startupCoverageActive,
                isBatteryCamera: isBatteryCamera
            )
            if let fallbackStartedAt = state.startupState.liveFallbackStartedAt,
               !feed.isStreaming,
               now.timeIntervalSince(fallbackStartedAt) >= liveStartTimeout,
               feed.stopLiveIfNeeded(reason: .startupTimeout) {
                recordTelemetry(
                    "startup live start timed out \(feed.id) elapsed=\(formatSeconds(now.timeIntervalSince(fallbackStartedAt)))"
                )
            }

            guard isVisibleOnWall(feed), isBatteryCamera else {
                state.batteryWakeLeaseStartedAt = nil
                state.batteryWakeRetryAfter = nil
                state.consecutiveBatteryWakeFailures = 0
                feedScheduleStates[feed.id] = state
                continue
            }

            if hasTrustedBatteryStill(feed, at: now) {
                state.batteryWakeLeaseStartedAt = nil
                state.batteryWakeRetryAfter = nil
                state.consecutiveBatteryWakeFailures = 0
                feedScheduleStates[feed.id] = state
                continue
            }

            if let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt,
               BatteryWakeLeaseTimeoutPolicy.hasTimedOut(
                   isStreaming: feed.isStreaming,
                   liveStartedAt: feed.liveStartedAt,
                   batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
                   warmup: batteryCaptureWarmup,
                   leaseDuration: batteryWakeLeaseDuration,
                   liveStartTimeout: batteryWakeLiveStartTimeout,
                   now: now
               ) {
                telemetryStartupMilestones.recordBatteryWakeTimeout(feedID: feed.id, at: elapsedSinceSession(now))
                recordTelemetry("battery wake timed out \(feed.id) streaming=\(feed.isStreaming)")
                feed.stopLiveIfNeeded()
                state = recordBatteryWakeFailure(state, for: feed.id, at: now)
            }

            feedScheduleStates[feed.id] = state
        }
    }

    private func updateBatteryWakeLease(
        for feedID: String,
        decision: PresentationDecision,
        at now: Date
    ) {
        guard var state = feedScheduleStates[feedID] else { return }

        guard preferences.isBatteryWakeCamera(id: feedID) else {
            state.batteryWakeLeaseStartedAt = nil
            state.batteryWakeRetryAfter = nil
            state.consecutiveBatteryWakeFailures = 0
            feedScheduleStates[feedID] = state
            return
        }

        guard decision.recoveryPhase == .batteryCapture else { return }
        guard state.batteryWakeLeaseStartedAt == nil else { return }

        state.batteryWakeLeaseStartedAt = now
        state.batteryWakeRetryAfter = nil
        feedScheduleStates[feedID] = state
        telemetryStartupMilestones.recordBatteryWakeLeaseStarted(feedID: feedID, at: elapsedSinceSession(now))
        recordTelemetry("battery wake lease started \(feedID)")
    }

    private func updateBatteryCaptureTrust(for feedID: String, at now: Date) {
        guard let feed = feeds.first(where: { $0.id == feedID }),
              var state = feedScheduleStates[feedID] else {
            return
        }

        guard BatteryTrustedStillCapturePolicy.shouldCapture(
            isBatteryCamera: feed.isBatteryWakeCamera,
            isStreaming: feed.isStreaming,
            liveStartedAt: feed.liveStartedAt,
            batteryStillDate: feed.batteryStillDate,
            batteryWakeLeaseStartedAt: state.batteryWakeLeaseStartedAt,
            allowsUnleasedCapture: sessionMode == .constrained,
            warmup: batteryCaptureWarmup,
            now: now
        ) else {
            return
        }

        feed.markBatteryStillCaptured(at: now)
        state.batteryWakeLeaseStartedAt = nil
        state.batteryWakeRetryAfter = nil
        state.consecutiveBatteryWakeFailures = 0
        applyStartupEvent(.trustedImageObserved, feedID: feedID, state: &state)
        feedScheduleStates[feedID] = state
        telemetryStartupMilestones.recordBatteryTrustedStill(feedID: feedID, at: elapsedSinceSession(now))
        recordTelemetry("battery trusted still captured \(feedID)")
    }

    @discardableResult
    private func concludeBatteryWake(for feedID: String, at date: Date) -> Bool {
        guard var state = feedScheduleStates[feedID], state.batteryWakeLeaseStartedAt != nil else {
            return false
        }

        if didCaptureBatteryStill(for: feedID, since: state.batteryWakeLeaseStartedAt) {
            state.batteryWakeLeaseStartedAt = nil
            state.batteryWakeRetryAfter = nil
            state.consecutiveBatteryWakeFailures = 0
            applyStartupEvent(.trustedImageObserved, feedID: feedID, state: &state)
        } else {
            feeds.first { $0.id == feedID }?.stopLiveIfNeeded()
            telemetryStartupMilestones.recordBatteryWakeFailure(feedID: feedID, at: elapsedSinceSession(date))
            recordTelemetry("battery wake failed \(feedID)")
            state = recordBatteryWakeFailure(state, for: feedID, at: date)
        }
        feedScheduleStates[feedID] = state
        return true
    }

    private func recordBatteryWakeFailure(
        _ originalState: FeedScheduleState,
        for feedID: String,
        at date: Date
    ) -> FeedScheduleState {
        var state = originalState
        state.batteryWakeLeaseStartedAt = nil
        state.consecutiveBatteryWakeFailures += 1
        state.batteryWakeRetryAfter = date.addingTimeInterval(
            batteryWakeBackoff(for: state.consecutiveBatteryWakeFailures)
        )
        applyStartupEvent(.liveFailed, feedID: feedID, state: &state)
        return state
    }

    private func didCaptureBatteryStill(for feedID: String, since leaseStartedAt: Date?) -> Bool {
        guard let leaseStartedAt,
              let feed = feeds.first(where: { $0.id == feedID }),
              let batteryStillDate = feed.batteryStillDate else {
            return false
        }

        return batteryStillDate >= leaseStartedAt
    }

    private func hasTrustedBatteryStill(_ feed: CameraFeedCoordinator, at date: Date = Date()) -> Bool {
        guard preferences.isBatteryWakeCamera(id: feed.id),
              let batteryStillDate = feed.batteryStillDate else {
            return false
        }

        return max(0, date.timeIntervalSince(batteryStillDate)) <= preferences.batteryWakeTriggerThreshold
    }

    private func queueSnapshotRefresh(
        for feedID: String,
        priority: SnapshotPriority? = nil,
        at date: Date = Date()
    ) {
        guard var state = feedScheduleStates[feedID],
              let feed = feeds.first(where: { $0.id == feedID }) else { return }
        let resolvedPriority = priority ?? currentRecoveryPlan.decisionsByID[feedID]?.snapshotPriority ?? .refresh
        guard SnapshotQueueAdmissionPolicy.shouldQueue(
            isBatteryCamera: preferences.isBatteryWakeCamera(id: feed.id),
            priority: resolvedPriority
        ) else {
            return
        }
        if (startupCoverageActive || (startupLiveRampState.map { $0.mode != .completed } ?? false)),
           state.startupState.resolution == .trusted {
            return
        }
        let eligibleAt: Date
        if startupCoverageActive,
           state.startupState.snapshotAttempted,
           state.startupState.snapshotFailed {
            guard let recoveryEligibleAt = StartupSnapshotRecoveryPolicy.retryEligibleDate(
                startupCoverageActive: true,
                startupState: state.startupState,
                snapshotFailedAt: state.lastSnapshotFailureAt,
                lastRequestIssuedAt: state.lastSnapshotRequestIssuedAt,
                priority: resolvedPriority
            ) else { return }
            eligibleAt = max(date, recoveryEligibleAt)
        } else {
            eligibleAt = SnapshotQueuePolicy.nextEligibleDate(
                current: .distantPast,
                requestedAt: date,
                lastRequestIssuedAt: state.lastSnapshotRequestIssuedAt,
                minimumInterval: SnapshotQueuePolicy.minimumRefreshInterval(for: resolvedPriority)
            )
        }
        let didQueue = state.snapshotWorkState.enqueue(priority: resolvedPriority, eligibleAt: eligibleAt)
        feedScheduleStates[feedID] = state
        if didQueue {
            telemetryStartupMilestones.recordSnapshotQueued(feedID: feedID, at: elapsedSinceSession(date))
            if startupCoverageActive, state.startupState.resolution == .recovering {
                recordTelemetry(
                    "snapshot recovery continuing \(feedID) nextIn=\(optionalSeconds(secondsUntil(eligibleAt, from: date)))"
                )
            }
            recordTelemetry(
                "snapshot queued \(feedID) priority=\(resolvedPriority) nextIn=\(optionalSeconds(secondsUntil(eligibleAt, from: date)))"
            )
        }
    }

    private func isVisibleOnWall(_ feed: CameraFeedCoordinator) -> Bool {
        BatteryCameraVisibilityPolicy.isVisible(
            isHomeKitVisible: feed.isVisibleOnWall,
            isBatteryCamera: preferences.isBatteryWakeCamera(id: feed.id),
            batteryCameraVisibilityEnabled: preferences.isBatteryCameraVisibilityEnabled,
            showsBatteryCameraVisibilityToggle: preferences.showsBatteryCameraVisibilityToggle
        )
    }

    private func reconcileHiddenBatteryCameraWork() {
        guard !preferences.isBatteryCameraVisibilityEnabled else { return }

        for feed in feeds where preferences.isBatteryWakeCamera(id: feed.id) {
            feed.stopLiveIfNeeded()

            if focusedFeedID == feed.id {
                focusedFeedID = nil
            }

            guard var state = feedScheduleStates[feed.id] else { continue }
            state.snapshotWorkState = .idle
            state.batteryWakeLeaseStartedAt = nil
            state.batteryWakeRetryAfter = nil
            state.consecutiveBatteryWakeFailures = 0
            applyStartupEvent(.reset, feedID: feed.id, state: &state)
            feedScheduleStates[feed.id] = state
        }

        liveCapacity = min(liveCapacity, wallFeeds.count)
        if wallFeeds.isEmpty {
            liveCapacityExpansionBlockedUntil = nil
            liveCapacityIncludesUnconfirmedMemory = false
            startupCoverageActive = true
            startupLiveRampState = nil
            wifiLiveBurstState = nil
        }
    }

    private func serviceSnapshotQueue() {
        guard isAppActive else { return }
        let now = Date()
        guard wifiLiveBurstState?.allowsSnapshotIssue(at: now) ?? true else { return }
        let feedLookup = Dictionary(uniqueKeysWithValues: wallFeeds.map { ($0.id, $0) })
        let snapshotFeeds = currentRecoveryPlan.orderedSnapshotIDs.compactMap { feedLookup[$0] }
        let activeLimit = effectiveMaxConcurrentSnapshotRequests(at: now)
        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        let outstandingLimit = effectiveMaxOutstandingSnapshotRequests(
            from: planningSnapshots,
            at: now
        )
        var capacity = SnapshotAdmissionPolicy.capacity(
            states: feedScheduleStates.values.map(\.snapshotWorkState),
            activeLimit: activeLimit,
            outstandingLimit: max(1, outstandingLimit)
        )
        telemetryStartupMilestones.recordSnapshotConcurrency(
            active: capacity.activeCount,
            outstanding: capacity.outstandingCount
        )

        guard capacity.availableActiveSlots > 0, capacity.availableOutstandingSlots > 0 else { return }

        let dueFeeds = snapshotFeeds
            .filter { feed in
                guard let state = feedScheduleStates[feed.id] else { return false }
                guard case .queued(_, let eligibleAt) = state.snapshotWorkState else { return false }
                return eligibleAt <= now
            }

        for feed in dueFeeds {
            guard capacity.availableActiveSlots > 0, capacity.availableOutstandingSlots > 0 else { break }
            if issueSnapshotRequest(for: feed, at: now) {
                capacity = SnapshotAdmissionPolicy.capacity(
                    states: feedScheduleStates.values.map(\.snapshotWorkState),
                    activeLimit: activeLimit,
                    outstandingLimit: max(1, outstandingLimit)
                )
                telemetryStartupMilestones.recordSnapshotConcurrency(
                    active: capacity.activeCount,
                    outstanding: capacity.outstandingCount
                )
            }
        }
    }

    @discardableResult
    private func issueSnapshotRequest(for feed: CameraFeedCoordinator, at date: Date) -> Bool {
        guard var state = feedScheduleStates[feed.id] else { return false }
        guard case .queued(let priority, let eligibleAt) = state.snapshotWorkState,
              eligibleAt <= date else { return false }

        let requestID = nextSnapshotRequestID
        if feed.requestSnapshot(requestID: requestID) {
            nextSnapshotRequestID += 1
            state.snapshotWorkState = .pending(
                SnapshotPendingRequest(
                    id: requestID,
                    priority: priority,
                    issuedAt: date,
                    timeoutReportedAt: nil
                )
            )
            state.lastSnapshotRequestIssuedAt = date
            applyStartupEvent(.snapshotRequested(at: date), feedID: feed.id, state: &state)
            feedScheduleStates[feed.id] = state
            telemetryStartupMilestones.recordSnapshotIssued(feedID: feed.id, at: elapsedSinceSession(date))
            recordTelemetry("snapshot issued \(feed.id) request=\(requestID)")
            return true
        } else {
            recordTelemetry("snapshot request rejected \(feed.id)")
            applyStartupEvent(.snapshotRequested(at: date), feedID: feed.id, state: &state)
            applyStartupEvent(
                .snapshotFailed(entersRecovery: restrictedSnapshotFailureEntersRecovery),
                feedID: feed.id,
                state: &state
            )
            state.lastSnapshotFailureAt = date
            if let eligibleAt = StartupSnapshotRecoveryPolicy.retryEligibleDate(
                startupCoverageActive: startupCoverageActive,
                startupState: state.startupState,
                snapshotFailedAt: date,
                lastRequestIssuedAt: state.lastSnapshotRequestIssuedAt,
                priority: priority
            ) {
                state.snapshotWorkState = .queued(priority: priority, eligibleAt: eligibleAt)
            } else {
                state.snapshotWorkState = .idle
            }
            feedScheduleStates[feed.id] = state
            return false
        }
    }

    private func handleSnapshotResult(
        for feedID: String,
        requestID: SnapshotRequestID?,
        result: SnapshotRequestResult
    ) {
        guard isCurrentSnapshotRequest(feedID: feedID, requestID: requestID) else {
            if acceptLateFirstSnapshotSuccess(for: feedID, requestID: requestID, result: result, at: Date()) {
                refreshPresentation(focusedFeedID: focusedFeedID)
                return
            }

            recordTelemetry(
                SnapshotResultTelemetry.staleSchedulerResultIgnoredMessage(
                    feedID: feedID,
                    requestID: requestID,
                    currentRequestID: feedScheduleStates[feedID]?.snapshotWorkState.pendingRequest?.id,
                    result: result,
                    now: Date()
                )
            )
            return
        }

        switch result {
        case .success(let captureDate):
            guard var state = feedScheduleStates[feedID] else { return }
            let callbackAt = Date()
            let callbackLatency = state.snapshotWorkState.pendingRequest.map {
                max(0, callbackAt.timeIntervalSince($0.issuedAt))
            }
            state.lastSnapshotSuccessAt = captureDate
            state.lastSnapshotFailureAt = nil
            state.snapshotWorkState = .idle
            applyStartupEvent(.snapshotSucceeded, feedID: feedID, state: &state)
            feedScheduleStates[feedID] = state
            telemetryStartupMilestones.recordSnapshotSuccess(
                feedID: feedID,
                callbackLatency: callbackLatency,
                at: elapsedSinceSession(callbackAt)
            )
            recordTelemetry("snapshot success \(feedID) request=\(requestID.map(String.init) ?? "nil") callbackLatency=\(optionalSeconds(callbackLatency)) captureAge=\(formatSeconds(max(0, callbackAt.timeIntervalSince(captureDate))))")
        case .failure(let error):
            let callbackAt = Date()
            let callbackLatency = feedScheduleStates[feedID]?.snapshotWorkState.pendingRequest.map {
                max(0, callbackAt.timeIntervalSince($0.issuedAt))
            }
            let failurePhase = snapshotFailurePhase(for: feedID)
            telemetryStartupMilestones.recordSnapshotFailure(
                feedID: feedID,
                callbackLatency: callbackLatency,
                phase: failurePhase,
                at: elapsedSinceSession(callbackAt)
            )
            recordTelemetry(
                "snapshot failure \(feedID) request=\(requestID.map(String.init) ?? "nil") phase=\(failurePhase) callbackLatency=\(optionalSeconds(callbackLatency)) error=\(transportErrorLabel(error))"
            )
            handleSnapshotFailure(for: feedID, at: callbackAt)
        }

        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func acceptLateFirstSnapshotSuccess(
        for feedID: String,
        requestID: SnapshotRequestID?,
        result: SnapshotRequestResult,
        at now: Date
    ) -> Bool {
        guard wallFeeds.contains(where: { $0.id == feedID }) else {
            return false
        }

        guard SnapshotRequestMatchPolicy.acceptsLateFirstSuccess(
            result: result,
            hasTrustedImage: hasTrustedImage(feedID: feedID, at: now),
            staleThreshold: preferences.staleVisualHighlightThreshold,
            now: now
        ) else {
            return false
        }

        guard case .success(let captureDate) = result,
              var state = feedScheduleStates[feedID] else {
            return false
        }

        state.lastSnapshotSuccessAt = captureDate
        state.lastSnapshotFailureAt = nil
        if !state.snapshotWorkState.isOutstanding {
            state.snapshotWorkState = .idle
        }
        applyStartupEvent(.snapshotSucceeded, feedID: feedID, state: &state)
        feedScheduleStates[feedID] = state
        telemetryStartupMilestones.recordSnapshotSuccess(feedID: feedID, callbackLatency: nil, at: elapsedSinceSession(now))
        recordTelemetry(
            "snapshot late success accepted \(feedID) request=\(requestID.map(String.init) ?? "nil") current=\(state.snapshotWorkState.pendingRequest.map { String($0.id) } ?? "nil") captureAge=\(formatSeconds(max(0, now.timeIntervalSince(captureDate))))"
        )
        return true
    }

    private func isCurrentSnapshotRequest(feedID: String, requestID: SnapshotRequestID?) -> Bool {
        guard let state = feedScheduleStates[feedID] else {
            return false
        }

        return SnapshotRequestMatchPolicy.isCurrent(
            currentRequestID: state.snapshotWorkState.pendingRequest?.id,
            resultRequestID: requestID,
            isInFlight: state.snapshotWorkState.isOutstanding
        )
    }

    private func snapshotFailurePhase(for feedID: String) -> String {
        guard let state = feedScheduleStates[feedID] else { return "unknown" }
        if state.startupState.resolution == .recovering {
            return "recovering"
        }
        if startupCoverageActive {
            return "initialStartup"
        }
        if state.snapshotWorkState.pendingRequest?.priority == .refresh {
            return "routineRefresh"
        }
        return "backgroundRecovery"
    }

    private func hasTrustedImage(feedID: String, at now: Date) -> Bool {
        guard let feed = wallFeeds.first(where: { $0.id == feedID }) else {
            return false
        }

        if feed.isStreaming {
            return true
        }

        let state = feedScheduleStates[feedID]
        guard let stillDate = feed.displayedStillDate ?? state?.lastSnapshotSuccessAt else {
            return false
        }

        return max(0, now.timeIntervalSince(stillDate)) <= preferences.staleVisualHighlightThreshold
    }

    private func applyStartupEvent(
        _ event: StartupCameraEvent,
        feedID: String,
        state: inout FeedScheduleState
    ) {
        let previousResolution = state.startupState.resolution
        state.startupState.apply(
            event,
            isBatteryCamera: preferences.isBatteryWakeCamera(id: feedID)
        )
        if startupCoverageActive,
           previousResolution != .recovering,
           state.startupState.resolution == .recovering {
            telemetryStartupMilestones.recordStartupRecovering(feedID: feedID)
        }
    }

    private var restrictedSnapshotFailureEntersRecovery: Bool {
        sessionNetworkClass != .wifi
    }

    private func handleSnapshotFailure(for feedID: String, at date: Date) {
        guard var state = feedScheduleStates[feedID] else { return }
        let priority = state.snapshotWorkState.pendingRequest?.priority
            ?? currentRecoveryPlan.decisionsByID[feedID]?.snapshotPriority
            ?? .refresh
        state.lastSnapshotFailureAt = date
        applyStartupEvent(
            .snapshotFailed(entersRecovery: restrictedSnapshotFailureEntersRecovery),
            feedID: feedID,
            state: &state
        )
        if let eligibleAt = StartupSnapshotRecoveryPolicy.retryEligibleDate(
            startupCoverageActive: startupCoverageActive,
            startupState: state.startupState,
            snapshotFailedAt: date,
            lastRequestIssuedAt: state.lastSnapshotRequestIssuedAt,
            priority: priority
        ) {
            state.snapshotWorkState = .queued(priority: priority, eligibleAt: eligibleAt)
        } else {
            state.snapshotWorkState = .idle
        }
        feedScheduleStates[feedID] = state
    }

    private func handleSnapshotTimeouts() {
        let now = Date()

        for (feedID, var state) in feedScheduleStates {
            guard let request = state.snapshotWorkState.pendingRequest,
                  now.timeIntervalSince(request.issuedAt) > snapshotRequestTimeout,
                  state.snapshotWorkState.markOverdue(at: now) else { continue }

            applyStartupEvent(
                .snapshotFailed(entersRecovery: restrictedSnapshotFailureEntersRecovery),
                feedID: feedID,
                state: &state
            )
            feedScheduleStates[feedID] = state
            telemetryStartupMilestones.recordSnapshotTimeout(feedID: feedID, at: elapsedSinceSession(now))
            recordTelemetry("snapshot overdue \(feedID) request=\(request.id) ownership=retained")
        }
    }

    private func batteryWakeBackoff(for failures: Int) -> TimeInterval {
        switch failures {
        case 0:
            0
        case 1:
            2
        case 2:
            4
        default:
            8
        }
    }

    private func handleConstrainedSignal(from feedID: String) {
        let now = Date()
        if let feed = feeds.first(where: { $0.id == feedID }), !isVisibleOnWall(feed) {
            reconcileHiddenBatteryCameraWork()
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        telemetryStartupMilestones.recordConstrainedSignal(feedID: feedID, at: elapsedSinceSession(now))
        recordTelemetry("constrained signal \(feedID) mode=\(sessionMode) liveCapacity=\(liveCapacity)")
        startupLiveRampState = nil
        if keepBatteryWakeLeaseAliveAfterConstrainedSignal(for: feedID, at: now) {
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        let didConcludeBatteryWake = concludeBatteryWake(for: feedID, at: now)
        if !didConcludeBatteryWake {
            queueSnapshotRefresh(for: feedID)
        }

        liveCapacityExpansionBlockedUntil = now.addingTimeInterval(
            CameraSchedulingDefaults.liveCapacityExpansionRetryDelay
        )

        let currentLiveCount = wallFeeds.filter {
            $0.id != feedID && $0.isStreaming
        }.count
        let visibleFeedCount = wallFeeds.count
        let visibleCameraIDs = wallFeeds.map(\.id)
        let rememberedCapacity = currentLiveCount == 0
            ? preferences.rememberedRestrictedLiveCapacity(
                homeID: selectedHome?.uniqueIdentifier.uuidString,
                visibleCameraIDs: visibleCameraIDs
            )
            : nil
        preferences.recordRestrictedLiveCapacityAfterRejection(
            currentLiveCount,
            homeID: selectedHome?.uniqueIdentifier.uuidString,
            visibleCameraIDs: visibleCameraIDs
        )

        if sessionMode == .optimistic {
            liveCapacity = RestrictedLiveCapacity.enteringAfterConstrainedSignal(
                currentLiveCount: currentLiveCount,
                visibleFeedCount: visibleFeedCount,
                rememberedCapacity: rememberedCapacity
            )
            liveCapacityIncludesUnconfirmedMemory = rememberedCapacity != nil && currentLiveCount == 0
            enterConstrainedMode(at: now)
            return
        }

        if liveCapacityIncludesUnconfirmedMemory {
            liveCapacity = RestrictedLiveCapacity.enteringAfterConstrainedSignal(
                currentLiveCount: currentLiveCount,
                visibleFeedCount: visibleFeedCount
            )
            liveCapacityIncludesUnconfirmedMemory = false
        } else {
            liveCapacity = RestrictedLiveCapacity.afterConstrainedSignal(
                currentLiveCount: currentLiveCount,
                visibleFeedCount: visibleFeedCount
            )
        }
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func keepBatteryWakeLeaseAliveAfterConstrainedSignal(for feedID: String, at now: Date) -> Bool {
        guard preferences.isBatteryWakeCamera(id: feedID),
              let feed = feeds.first(where: { $0.id == feedID }),
              let state = feedScheduleStates[feedID],
              let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt else {
            return false
        }

        guard BatteryWakeConstrainedSignalPolicy.shouldKeepLeaseAlive(
            isBatteryCamera: feed.isBatteryWakeCamera,
            isStreaming: feed.isStreaming,
            liveStartedAt: feed.liveStartedAt,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
            didCaptureTrustedStill: didCaptureBatteryStill(for: feedID, since: batteryWakeLeaseStartedAt),
            warmup: batteryCaptureWarmup,
            leaseDuration: batteryWakeLeaseDuration,
            liveStartTimeout: batteryWakeLiveStartTimeout,
            now: now
        ) else {
            return false
        }

        feedScheduleStates[feedID] = state
        recordTelemetry("constrained signal preserved battery lease \(feedID)")
        return true
    }

    private func cancelBatteryWakeLeasesSupersededByFocus(at now: Date) {
        guard focusedFeedID != nil else { return }

        for (feedID, state) in feedScheduleStates where state.batteryWakeLeaseStartedAt != nil {
            guard currentRecoveryPlan.decisionsByID[feedID]?.recoveryPhase != .batteryCapture else {
                continue
            }

            var state = state
            state.batteryWakeLeaseStartedAt = nil
            state.batteryWakeRetryAfter = nil
            feedScheduleStates[feedID] = state
            recordTelemetry("battery wake lease cancelled by focus \(feedID)")
        }
    }

    private func enterConstrainedMode(at now: Date) {
        guard sessionMode != .constrained else {
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        sessionMode = .constrained
        telemetryStartupMilestones.recordEnteredConstrainedMode(liveCapacity: liveCapacity, at: elapsedSinceSession(now))
        recordTelemetry("entered constrained mode liveCapacity=\(liveCapacity)")
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func handleAvailabilityChange(for feedID: String) {
        if focusedFeedID == feedID {
            focusedFeedID = nil
        }

        if var state = feedScheduleStates[feedID] {
            state.batteryWakeLeaseStartedAt = nil
            if !state.snapshotWorkState.isOutstanding {
                state.snapshotWorkState = .idle
                applyStartupEvent(.reset, feedID: feedID, state: &state)
            }
            state.batteryWakeRetryAfter = nil
            state.consecutiveBatteryWakeFailures = 0
            feedScheduleStates[feedID] = state
        }

        let visibleCount = wallFeeds.count
        liveCapacity = min(liveCapacity, visibleCount)
        if visibleCount == 0 {
            liveCapacityExpansionBlockedUntil = nil
            liveCapacityIncludesUnconfirmedMemory = false
            startupCoverageActive = true
            startupLiveRampState = nil
            wifiLiveBurstState = nil
        }

        objectWillChange.send()
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func recordRememberedRestrictedLiveCapacity(_ capacity: Int) {
        preferences.recordConfirmedRestrictedLiveCapacity(
            capacity,
            homeID: selectedHome?.uniqueIdentifier.uuidString,
            visibleCameraIDs: wallFeeds.map(\.id)
        )
    }

    private func updateTrustedImageMilestones(from planningSnapshots: [FeedPlanningSnapshot], at now: Date) {
        guard !planningSnapshots.isEmpty else { return }

        let elapsed = elapsedSinceSession(now)
        for snapshot in planningSnapshots where snapshot.hasTrustedImage(at: now) {
            let source: String
            if snapshot.isStreaming {
                source = "live"
            } else if snapshot.isBatteryWakeCamera {
                source = "batteryStill"
            } else {
                source = "cachedSnapshot"
            }
            telemetryStartupMilestones.recordTrustedImage(
                feedID: snapshot.id,
                source: source,
                at: elapsed
            )
        }

        if planningSnapshots.allSatisfy({ $0.hasTrustedImage(at: now) }) {
            telemetryStartupMilestones.recordAllVisibleFeedsTrusted(at: elapsed)
        }
    }

    private func updateStartupCoverage(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) {
        guard startupCoverageActive else { return }
        guard !planningSnapshots.isEmpty else {
            startupCoverageActive = false
            startupLiveRampState = nil
            wifiLiveBurstState = nil
            return
        }

        for snapshot in planningSnapshots where snapshot.hasTrustedImage(at: now) {
            guard var state = feedScheduleStates[snapshot.id] else { continue }
            applyStartupEvent(.trustedImageObserved, feedID: snapshot.id, state: &state)
            if case .queued = state.snapshotWorkState {
                state.snapshotWorkState = .idle
            }
            feedScheduleStates[snapshot.id] = state
        }

        let recoveringIDs = planningSnapshots.compactMap { snapshot -> String? in
            feedScheduleStates[snapshot.id]?.startupState.resolution == .recovering
                ? snapshot.id
                : nil
        }
        let isComplete = planningSnapshots.allSatisfy {
            feedScheduleStates[$0.id]?.startupState.resolution != .pending
        }
        guard isComplete else { return }

        startupCoverageActive = false
        telemetryStartupMilestones.recordStartupCoverageEnded(
            recoveringFeedIDs: recoveringIDs,
            at: elapsedSinceSession(now)
        )
        recordTelemetry(
            "startup first pass ended recovering=\(recoveringIDs.isEmpty ? "none" : recoveringIDs.joined(separator: ","))"
        )
    }

    private func updateWiFiLiveBurst(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) {
        guard var burst = wifiLiveBurstState else { return }
        let previousMode = burst.mode
        let streamingIDs = Set(planningSnapshots.filter(\.isStreaming).map(\.id))

        let visibleIDs = Set(planningSnapshots.map(\.id))
        if networkPathClassifier.currentClass != .wifi
            || (!burst.liveIDs.isEmpty && burst.liveIDs != visibleIDs) {
            burst.invalidatePath(streamingIDs: streamingIDs)
        } else {
            burst.evaluate(streamingIDs: streamingIDs, at: now)
        }
        wifiLiveBurstState = burst

        guard burst.mode != previousMode else { return }
        recordTelemetry(
            "wifi live burst mode=\(wifiLiveBurstModeLabel) survivors=\(burst.survivingLiveIDs.sorted().joined(separator: ","))"
        )

        if case .closed = burst.mode {
            enterConstrainedAfterWiFiBurst(at: now)
        } else if burst.mode == .completed {
            telemetryStartupMilestones.recordAllVisibleFeedsLive(at: elapsedSinceSession(now))
        }
    }

    private func enterConstrainedAfterWiFiBurst(at now: Date) {
        guard sessionMode == .optimistic else { return }

        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        liveCapacity = RestrictedLiveCapacity.enteringAfterConstrainedSignal(
            currentLiveCount: currentLiveCount,
            visibleFeedCount: wallFeeds.count
        )
        liveCapacityExpansionBlockedUntil = now.addingTimeInterval(
            CameraSchedulingDefaults.liveCapacityExpansionRetryDelay
        )
        liveCapacityIncludesUnconfirmedMemory = false
        startupLiveRampState = nil
        sessionMode = .constrained
        telemetryStartupMilestones.recordEnteredConstrainedMode(
            liveCapacity: liveCapacity,
            at: elapsedSinceSession(now)
        )
        recordTelemetry(
            "wifi live burst fallback entered constrained mode liveCapacity=\(liveCapacity)"
        )
    }

    private var wifiLiveBurstModeLabel: String {
        guard let wifiLiveBurstState else { return "none" }
        return switch wifiLiveBurstState.mode {
        case .inactive: "inactive"
        case .headStart: "headStart"
        case .active: "active"
        case .batteryGrace: "batteryGrace"
        case .completed: "completed"
        case .closed(let reason): "closed:\(reason.rawValue)"
        }
    }

    private func updateStartupLiveRamp(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) {
        guard sessionMode == .optimistic, var ramp = startupLiveRampState else { return }

        let previousMode = ramp.mode
        let previousIDs = ramp.selectedIDs
        let selectedIDs = ramp.reconcile(
            priorityIDs: planningSnapshots.sorted { $0.priorityIndex < $1.priorityIndex }.map(\.id),
            streamingIDs: Set(planningSnapshots.filter(\.isStreaming).map(\.id)),
            focusedID: focusedFeedID,
            now: now
        )
        startupLiveRampState = ramp

        if ramp.mode != previousMode || selectedIDs != previousIDs {
            recordTelemetry(
                "startup live ramp mode=\(ramp.mode.rawValue) pendingLimit=\(ramp.maxPendingCount) live=\(selectedIDs.sorted().joined(separator: ","))"
            )
        }
        if ramp.mode == .completed, previousMode != .completed {
            telemetryStartupMilestones.recordAllVisibleFeedsLive(at: elapsedSinceSession(now))
            recordTelemetry("startup live ramp completed")
        }
    }

    private func handleLiveTransportEvent(for feedID: String, event: CameraLiveTransportEvent) {
        switch event {
        case .startRequested(let requestedAt, let restarted):
            if var state = feedScheduleStates[feedID], state.startupState.resolution != .trusted {
                applyStartupEvent(.liveRequested(at: requestedAt), feedID: feedID, state: &state)
                feedScheduleStates[feedID] = state
            }
            recordTelemetry(
                "live start requested \(feedID) restarted=\(restarted)",
                at: requestedAt
            )
        case .started(let startedAt, let callbackLatency):
            let completedCapacityProbe = liveAdmissionController.activeCapacityProbeFeedID == feedID
            liveAdmissionController.recordSuccess(feedID: feedID)
            if completedCapacityProbe {
                recordTelemetry(
                    "capacity probe succeeded \(feedID) sessionCeiling=\(liveAdmissionController.softContentionSessionCeiling.map(String.init) ?? "nil")",
                    at: startedAt
                )
            }
            let startedAtElapsed = elapsedSinceSession(startedAt)
            let burstOwnsLiveSelection = wifiLiveBurstState.map { state in
                switch state.mode {
                case .headStart, .active, .batteryGrace, .completed: true
                case .inactive, .closed: false
                }
            } ?? false
            let restrictedPhase = restrictedStartupPhase(
                from: planningSnapshots(at: startedAt, focusedFeedID: focusedFeedID),
                at: startedAt
            )
            if sessionMode == .optimistic,
               !burstOwnsLiveSelection,
               restrictedPhase == nil || restrictedPhase?.isOrdinaryLiveGateOpen == true {
                var ramp = startupLiveRampState ?? StartupLiveRampState(
                    initialSelectedIDs: Set(currentRecoveryPlan.decisionsByID.compactMap { id, decision in
                        decision.presentationMode == .live ? id : nil
                    })
                )
                let previousMode = ramp.mode
                ramp.recordLiveStarted(
                    feedID: feedID,
                    elapsed: startedAtElapsed,
                    fastThreshold: startupFastLocalLiveThreshold
                )
                startupLiveRampState = ramp
                if previousMode == .probing {
                    recordTelemetry(
                        "startup live ramp classified mode=\(ramp.mode.rawValue) by=\(feedID) elapsed=\(formatSeconds(startedAtElapsed))",
                        at: startedAt
                    )
                }
            }
            if var state = feedScheduleStates[feedID], state.startupState.resolution != .trusted {
                applyStartupEvent(
                    burstOwnsLiveSelection ? .plainLiveStarted : .liveStarted,
                    feedID: feedID,
                    state: &state
                )
                feedScheduleStates[feedID] = state
            }
            telemetryStartupMilestones.recordLiveStarted(
                feedID: feedID,
                callbackLatency: callbackLatency,
                resolvesTrustedImage: !preferences.isBatteryWakeCamera(id: feedID) || burstOwnsLiveSelection,
                at: startedAtElapsed
            )
            recordTelemetry(
                "live started \(feedID) callbackLatency=\(optionalSeconds(callbackLatency))",
                at: startedAt
            )
        case .stopRequested(let requestedAt, let reason):
            recordTelemetry(
                "live stop requested \(feedID) reason=\(String(describing: reason))",
                at: requestedAt
            )
        case .stopped(let stoppedAt, let disposition, let callbackLatency):
            telemetryStartupMilestones.recordLiveStopped(
                feedID: feedID,
                callbackLatency: callbackLatency
            )
            let shouldFailCameraPath: Bool = switch disposition {
            case .startupTimedOut, .retryableTransport, .cameraFailure, .ended: true
            case .requestedStop, .softContention, .hardCapacity, .infrastructureUnavailable: false
            }
            if shouldFailCameraPath,
               var state = feedScheduleStates[feedID],
               state.startupState.resolution != .trusted {
                let isBatteryCamera = preferences.isBatteryWakeCamera(id: feedID)
                if startupLiveRampState != nil || state.startupState.liveAttempted || isBatteryCamera {
                    applyStartupEvent(.liveFailed, feedID: feedID, state: &state)
                }
                feedScheduleStates[feedID] = state
            }
            if shouldFailCameraPath, var ramp = startupLiveRampState {
                ramp.recordLiveStopped(
                    feedID: feedID,
                    at: stoppedAt,
                    isCapacitySignal: false,
                    retryDelay: CameraSchedulingDefaults.liveCapacityExpansionRetryDelay
                )
                startupLiveRampState = ramp
            }
            let burstWasOpen = wifiLiveBurstState.map { state in
                switch state.mode {
                case .headStart, .active, .batteryGrace: true
                case .inactive, .completed, .closed: false
                }
            } ?? false
            if burstWasOpen, var burst = wifiLiveBurstState {
                let streamingIDs = Set(wallFeeds.filter(\.isStreaming).map(\.id))
                if case .hardCapacity = disposition {
                    burst.recordCapacityRejection(streamingIDs: streamingIDs)
                } else if case .softContention = disposition {
                    burst.recordCapacityRejection(streamingIDs: streamingIDs)
                } else if disposition != .requestedStop {
                    burst.recordFailure(streamingIDs: streamingIDs)
                }
                wifiLiveBurstState = burst
            }
            recordTelemetry(
                "live stopped \(feedID) disposition=\(liveFailureDispositionLabel(disposition)) callbackLatency=\(optionalSeconds(callbackLatency)) error=\(transportErrorLabel(disposition.error))",
                at: stoppedAt
            )

            switch disposition {
            case .requestedStop:
                liveAdmissionController.cancelCapacityProbe(feedID: feedID)
                break
            case .softContention:
                let survivingStreamCount = wallFeeds.filter(\.isStreaming).count
                let outcome = liveAdmissionController.recordSoftContention(
                    feedID: feedID,
                    survivingStreamCount: survivingStreamCount,
                    at: stoppedAt
                )
                liveCapacity = min(liveCapacity, outcome.sessionCeiling)
                liveCapacityExpansionBlockedUntil = stoppedAt.addingTimeInterval(
                    CameraSchedulingDefaults.liveCapacityExpansionRetryDelay
                )
                liveCapacityIncludesUnconfirmedMemory = false
                if outcome.shouldYieldCamera,
                   var state = feedScheduleStates[feedID],
                   state.startupState.resolution != .trusted {
                    applyStartupEvent(.liveFailed, feedID: feedID, state: &state)
                    feedScheduleStates[feedID] = state
                    recordTelemetry(
                        "soft contention yielded startup lane \(feedID) attempt=\(outcome.attempt)",
                        at: stoppedAt
                    )
                }
                recordTelemetry(
                    "live retry queued \(feedID) disposition=softContention attempt=\(outcome.attempt) sessionCeiling=\(outcome.sessionCeiling) persisted=false retryIn=\(formatSeconds(outcome.retryDelay))",
                    at: stoppedAt
                )
                enterSerializedModePreservingCapacity(reason: "softContention", at: stoppedAt)
            case .hardCapacity:
                liveAdmissionController.cancelCapacityProbe(feedID: feedID)
                handleConstrainedSignal(from: feedID)
                return
            case .infrastructureUnavailable:
                liveAdmissionController.recordInfrastructureUnavailable(at: stoppedAt)
                recordTelemetry(
                    "live infrastructure backoff retryIn=\(optionalSeconds(liveAdmissionController.infrastructureRetryDelay(at: stoppedAt)))",
                    at: stoppedAt
                )
                if burstWasOpen {
                    enterSerializedModePreservingCapacity(reason: "infrastructureUnavailable", at: stoppedAt)
                }
            case .startupTimedOut, .retryableTransport, .cameraFailure, .ended:
                liveAdmissionController.recordRetryableFailure(feedID: feedID, at: stoppedAt)
                recordTelemetry(
                    "live retry queued \(feedID) disposition=\(liveFailureDispositionLabel(disposition)) retryIn=\(optionalSeconds(liveAdmissionController.retryDelay(feedID: feedID, at: stoppedAt)))",
                    at: stoppedAt
                )
                if burstWasOpen {
                    enterSerializedModePreservingCapacity(reason: "transportFailure", at: stoppedAt)
                }
            }
        }

        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func enterSerializedModePreservingCapacity(reason: String, at now: Date) {
        startupLiveRampState = nil
        if sessionMode != .constrained {
            sessionMode = .constrained
            telemetryStartupMilestones.recordEnteredConstrainedMode(
                liveCapacity: liveCapacity,
                at: elapsedSinceSession(now)
            )
        }
        recordTelemetry(
            "entered serialized mode reason=\(reason) preservedCapacity=\(liveCapacity)",
            at: now
        )
    }

    private func liveFailureDispositionLabel(_ disposition: CameraLiveFailureDisposition) -> String {
        switch disposition {
        case .requestedStop: "requestedStop"
        case .startupTimedOut: "startupTimedOut"
        case .softContention: "softContention"
        case .hardCapacity: "hardCapacity"
        case .infrastructureUnavailable: "infrastructureUnavailable"
        case .retryableTransport: "retryableTransport"
        case .cameraFailure: "cameraFailure"
        case .ended: "ended"
        }
    }

    private func effectiveMaxConcurrentSnapshotRequests(at now: Date) -> Int {
        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        return effectiveMaxConcurrentSnapshotRequests(from: planningSnapshots, at: now)
    }

    private func effectiveMaxConcurrentSnapshotRequests(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) -> Int {
        let nonBatterySnapshots = planningSnapshots.filter { !$0.isBatteryWakeCamera }
        let trustedCount = nonBatterySnapshots.filter { $0.hasTrustedImage(at: now) }.count
        return StartupSnapshotConcurrencyPolicy.effectiveLimit(
            isFirstFramePhaseActive: startupCoverageActive,
            usesRestrictedSnapshotOnlyStrategy: sessionNetworkClass != .wifi,
            nonBatteryTrustedCount: trustedCount,
            nonBatteryCount: nonBatterySnapshots.count
        )
    }

    private func effectiveMaxOutstandingSnapshotRequests(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) -> Int {
        let restrictedLiveGateClosed = restrictedStartupPhase(
            from: planningSnapshots,
            at: now
        ).map { !$0.isOrdinaryLiveGateOpen } ?? false
        return startupCoverageActive || restrictedLiveGateClosed
            ? CameraSchedulingDefaults.startupMaxOutstandingSnapshotRequests
            : maxConcurrentSnapshotRequests
    }

    private func elapsedSinceSession(_ date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(telemetrySessionStartedAt))
    }

    private var authorizationLabel: String {
        String(describing: authorizationStatus)
    }

    private var homeHubLabel: String {
        switch homeHubState {
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        case .notAvailable:
            "Not available"
        @unknown default:
            "Unknown"
        }
    }

    private func telemetryFeeds(at now: Date) -> [CameraTelemetryFeed] {
        wallFeeds.enumerated().map { index, feed in
            let state = feedScheduleStates[feed.id]
            let decision = currentRecoveryPlan.decisionsByID[feed.id]
            let pendingRequest = state?.snapshotWorkState.pendingRequest
            let nextEligibleSnapshotAt = state?.snapshotWorkState.queuedEligibleAt
            return CameraTelemetryFeed(
                priorityIndex: index,
                id: feed.id,
                name: feed.name,
                roomName: feed.roomName,
                isVisibleOnWall: feed.isVisibleOnWall,
                isReachable: feed.isReachable,
                isAvailableInSession: feed.isAvailableInSession,
                isHomeKitCameraActive: feed.isHomeKitCameraActive,
                isBatteryWakeCamera: feed.isBatteryWakeCamera,
                isStreaming: feed.isStreaming,
                isStartingLive: feed.isStartingLive,
                liveTransportPhase: String(describing: feed.liveTransportPhase),
                displayState: String(describing: feed.state),
                recencyTier: String(describing: feed.recencyTier),
                recoveryPhase: String(describing: feed.recoveryPhase),
                snapshotPriority: decision.map { String(describing: $0.snapshotPriority) } ?? "none",
                presentationMode: decision.map { String(describing: $0.presentationMode) } ?? "unknown",
                displayedStillAge: age(of: feed.displayedStillDate, at: now),
                lastSnapshotSuccessAge: age(of: state?.lastSnapshotSuccessAt, at: now),
                snapshotWorkState: snapshotWorkStateLabel(state?.snapshotWorkState),
                snapshotRequestID: pendingRequest.map { String($0.id) },
                snapshotInFlightAge: age(of: pendingRequest?.issuedAt, at: now),
                snapshotOverdueAge: age(of: pendingRequest?.timeoutReportedAt, at: now),
                nextEligibleSnapshotIn: secondsUntil(nextEligibleSnapshotAt, from: now),
                lastSnapshotRequestAge: age(of: state?.lastSnapshotRequestIssuedAt, at: now),
                startupCoverageResolution: state.map { String(describing: $0.startupState.resolution) } ?? "unknown",
                startupSnapshotAttempted: state?.startupState.snapshotAttempted ?? false,
                startupSnapshotPath: state?.startupState.snapshotPath.label ?? "unknown",
                startupLivePath: state?.startupState.livePath.label ?? "unknown",
                batteryStillAge: age(of: feed.batteryStillDate, at: now),
                nextBatteryCaptureDueIn: preferences.isBatteryWakeCamera(id: feed.id)
                    ? feed.batteryStillDate.map {
                        max(0, $0.addingTimeInterval(preferences.batteryWakeTriggerThreshold).timeIntervalSince(now))
                    }
                    : nil,
                batteryWakeLeaseAge: age(of: state?.batteryWakeLeaseStartedAt, at: now),
                batteryWakeRetryIn: secondsUntil(state?.batteryWakeRetryAfter, from: now),
                consecutiveBatteryWakeFailures: state?.consecutiveBatteryWakeFailures ?? 0,
                liveStartedAge: age(of: feed.liveStartedAt, at: now),
                liveStartRequestedAge: age(of: feed.liveStartRequestedAt, at: now),
                liveStopRequestedAge: age(of: feed.liveStopRequestedAt, at: now),
                liveStopReason: feed.liveStopReason.map { String(describing: $0) },
                lastErrorMessage: feed.lastErrorMessage
            )
        }
    }

    private func recordTelemetry(_ message: String, at date: Date = Date()) {
        guard telemetryEvents.last?.message != message else { return }
        telemetryEvents.append(
            CameraTelemetryEvent(
                sequence: nextTelemetrySequence,
                elapsed: max(0, date.timeIntervalSince(telemetrySessionStartedAt)),
                message: message
            )
        )
        nextTelemetrySequence += 1
        if telemetryEvents.count > maxTelemetryEvents {
            telemetryEvents.removeFirst(telemetryEvents.count - maxTelemetryEvents)
        }
    }
}

extension HomeKitCameraStore: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = manager.authorizationStatus
            self.rebuildHomesAndFeeds()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            self.rebuildHomesAndFeeds()
        }
    }
}

extension HomeKitCameraStore: HMHomeDelegate {
    nonisolated func home(_ home: HMHome, didUpdate homeHubState: HMHomeHubState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.homeHubState = homeHubState
        }
    }

    nonisolated func home(_ home: HMHome, didEncounterError error: any Error, for accessory: HMAccessory) {
        Task { @MainActor in
            _ = error
            _ = accessory
        }
    }
}

extension HomeKitCameraStore: HMAccessoryDelegate {
    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }.forEach {
                $0.refreshHomeKitCameraActiveStateIfNeeded(for: characteristic)
                $0.refreshBatteryPercentageIfNeeded(for: characteristic)
            }
            self.refreshPresentation(focusedFeedID: self.focusedFeedID)
        }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }.forEach { feed in
                feed.refreshSessionAvailabilityFromAccessory()
                guard var state = self.feedScheduleStates[feed.id] else { return }
                state.batteryWakeLeaseStartedAt = nil
                state.batteryWakeRetryAfter = nil
                state.consecutiveBatteryWakeFailures = 0
                if case .queued(let priority, _) = state.snapshotWorkState {
                    state.snapshotWorkState = .queued(priority: priority, eligibleAt: .distantPast)
                }
                self.feedScheduleStates[feed.id] = state
            }

            let visibleCount = self.wallFeeds.count
            self.liveCapacity = min(self.liveCapacity, visibleCount)
            if visibleCount == 0 {
                self.liveCapacityExpansionBlockedUntil = nil
                self.liveCapacityIncludesUnconfirmedMemory = false
                self.startupCoverageActive = true
                self.startupLiveRampState = nil
                self.wifiLiveBurstState = nil
            }

            self.objectWillChange.send()
            self.refreshPresentation(focusedFeedID: self.focusedFeedID)
        }
    }

    nonisolated func accessoryDidUpdateName(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }.forEach {
                $0.refreshMetadata()
            }
        }
    }

    nonisolated func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            self?.rebuildHomesAndFeeds()
        }
    }
}

private struct FeedScheduleState {
    var lastSnapshotSuccessAt: Date?
    var snapshotWorkState: SnapshotWorkState
    var lastSnapshotRequestIssuedAt: Date?
    var lastSnapshotFailureAt: Date?
    var batteryWakeLeaseStartedAt: Date?
    var batteryWakeRetryAfter: Date?
    var consecutiveBatteryWakeFailures: Int
    var startupState: StartupCameraState
}
