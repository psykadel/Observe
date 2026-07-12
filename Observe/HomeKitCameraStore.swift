import Foundation
import HomeKit

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
    private var liveCapacityExpansionBlockedUntil: Date?
    private var liveCapacityIncludesUnconfirmedMemory = false
    private var startupCoverageActive = true
    private var startupLiveRampState: StartupLiveRampState?
    private var wifiLiveBurstState: WiFiLiveBurstState?
    private var stalledStartupRescueAttempted = false
    private var stalledStartupRescueLiveIDs: Set<String>?
    private var lastLivePlanTelemetrySignature: String?
    private var sessionNetworkClass: CameraNetworkClass = .unknown
    private var telemetrySessionStartedAt = Date()
    private var telemetryEvents: [CameraTelemetryEvent] = []
    private var nextTelemetrySequence = 1
    private var telemetryStartupMilestones = CameraStartupTelemetryMilestones()
    private var nextSnapshotRequestID: SnapshotRequestID = 1
    private var sessionGeneration: UInt64 = 0

    private let snapshotRequestTimeout = CameraSchedulingDefaults.snapshotRequestTimeout
    private let startupFastLocalLiveThreshold: TimeInterval = 3
    private let maxTelemetryEvents = 240

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
            stalledStartupRescueAttempted = false
            stalledStartupRescueLiveIDs = nil
            lastLivePlanTelemetrySignature = nil
            currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
            feeds.forEach { $0.resetSessionState() }
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
        let snapshotCapacity = SnapshotAdmissionPolicy.capacity(
            states: feedScheduleStates.values.map(\.snapshotWorkState),
            activeLimit: effectiveMaxConcurrentSnapshotRequests(at: now),
            outstandingLimit: startupCoverageActive ? 4 : maxConcurrentSnapshotRequests
        )
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
            visibleFeedCount: wallFeeds.count,
            internalMaxConcurrentSnapshotRequests: maxConcurrentSnapshotRequests,
            effectiveMaxConcurrentSnapshotRequests: effectiveMaxConcurrentSnapshotRequests(at: now),
            snapshotRequestTimeout: snapshotRequestTimeout,
            untrustedSnapshotRefreshInterval: CameraSchedulingDefaults.untrustedSnapshotRefreshInterval,
            trustedSnapshotRefreshInterval: CameraSchedulingDefaults.minimumSnapshotRefreshInterval,
            batteryCaptureWarmup: batteryCaptureWarmup,
            batteryWakeLeaseDuration: batteryWakeLeaseDuration,
            batteryWakeLiveStartTimeout: batteryWakeLiveStartTimeout,
            startupCoverageActive: startupCoverageActive,
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
            liveCapacityExpansionBlockedUntil: liveCapacityExpansionBlockedUntil,
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
            feeds = []
            feedScheduleStates = [:]
            currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
            liveCapacity = 0
            liveCapacityExpansionBlockedUntil = nil
            liveCapacityIncludesUnconfirmedMemory = false
            startupCoverageActive = true
            startupLiveRampState = nil
            wifiLiveBurstState = nil
            return
        }

        home.delegate = self

        var discoveredFeeds: [CameraFeedCoordinator] = []
        for accessory in home.accessories {
            accessory.delegate = self

            let profiles = accessory.cameraProfiles ?? []
            for (index, profile) in profiles.enumerated() {
                let feed = CameraFeedCoordinator(accessory: accessory, profile: profile, profileIndex: index)
                feed.onSnapshotResult = { [weak self] feedID, requestID, result in
                    Task { @MainActor [weak self] in
                        guard let self, self.acceptsCallback(generation: callbackGeneration) else { return }
                        self.handleSnapshotResult(for: feedID, requestID: requestID, result: result)
                    }
                }
                feed.onLiveTransportEvent = { [weak self] feedID, event in
                    Task { @MainActor [weak self] in
                        guard let self, self.acceptsCallback(generation: callbackGeneration) else { return }
                        self.handleLiveTransportEvent(for: feedID, event: event)
                    }
                }
                feed.onAvailabilityChanged = { [weak self] feedID in
                    Task { @MainActor [weak self] in
                        guard let self, self.acceptsCallback(generation: callbackGeneration) else { return }
                        self.handleAvailabilityChange(for: feedID)
                    }
                }
                feed.refreshHomeKitCameraActiveState()
                feed.readHomeKitCameraActiveState()
                feed.readBatteryPercentage()
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

        sessionMode = .optimistic
        liveCapacity = wallFeeds.count
        liveCapacityExpansionBlockedUntil = nil
        liveCapacityIncludesUnconfirmedMemory = false
        startupCoverageActive = true
        startupLiveRampState = nil
        wifiLiveBurstState = nil
        stalledStartupRescueAttempted = false
        stalledStartupRescueLiveIDs = nil
        lastLivePlanTelemetrySignature = nil
        startSession()
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
        stalledStartupRescueAttempted = false
        stalledStartupRescueLiveIDs = nil
        lastLivePlanTelemetrySignature = nil
        let networkClass = networkPathClassifier.currentClass
        sessionNetworkClass = networkClass
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
        refreshPresentation(focusedFeedID: focusedFeedID)

        if wifiLiveBurstState?.mode == .headStart {
            let generation = sessionGeneration
            wifiLiveBurstHeadStartTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
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

        feeds.forEach { feed in
            feed.setBatteryWakeEnabled(preferences.isBatteryWakeCamera(id: feed.id))
            feed.setConfiguredStaleThreshold(
                preferences.isBatteryWakeCamera(id: feed.id)
                    ? preferences.batteryStaleThreshold
                    : preferences.staleVisualHighlightThreshold
            )
            feed.setConfiguredBatteryTrustedStillThreshold(preferences.batteryWakeTriggerThreshold)
            feed.setConfiguredBatteryCaptureWarmup(batteryCaptureWarmup)
        }

        let now = Date()
        reconcileFeedScheduleStates(at: now, focusedFeedID: focusedFeedID)

        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        updateTrustedImageMilestones(from: planningSnapshots, at: now)
        updateStartupCoverage(from: planningSnapshots, at: now)
        updateWiFiLiveBurst(from: planningSnapshots, at: now)
        updateStartupLiveRamp(from: planningSnapshots, at: now)
        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        let liveBudget: Int
        switch sessionMode {
        case .optimistic:
            liveBudget = planningSnapshots.count
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
            let hasBatteryCaptureDemand = planningSnapshots.contains {
                $0.needsBatteryCapture(
                    at: now,
                    leaseDuration: batteryWakeLeaseDuration,
                    warmup: batteryCaptureWarmup,
                    liveStartTimeout: batteryWakeLiveStartTimeout
                )
            }
            liveBudget = RestrictedLiveCapacity.planningBudget(
                knownCapacity: liveCapacity,
                visibleFeedCount: planningSnapshots.count,
                hasBatteryCaptureDemand: hasBatteryCaptureDemand,
                allVisibleFeedsTrusted: allVisibleFeedsTrusted,
                canProbeCapacity: canProbeCapacity
            )
        }
        let wiredStartupFeeds = planningSnapshots.filter { !$0.isBatteryWakeCamera }
        let allWiredSnapshotPathsAttempted = wiredStartupFeeds.allSatisfy {
            $0.hasTrustedImage(at: now) || $0.startupState.snapshotAttempted
        }
        let hasActiveSnapshotRequest = feedScheduleStates.values.contains {
            $0.snapshotWorkState.isActive
        }
        activateStalledStartupRescueIfNeeded(from: planningSnapshots, at: now)
        let startupLivePolicy: StartupLivePolicy
        if sessionMode == .optimistic,
           let wifiLiveBurstState,
           !wifiLiveBurstState.liveIDs.isEmpty {
            startupLivePolicy = .liveBurst(liveIDs: wifiLiveBurstState.liveIDs)
        } else if sessionMode == .optimistic,
           let startupLiveRampState,
           startupLiveRampState.mode != .completed {
            startupLivePolicy = .capacityRamp(liveIDs: startupLiveRampState.selectedIDs)
        } else if sessionMode == .optimistic,
                  let stalledStartupRescueLiveIDs,
                  !stalledStartupRescueLiveIDs.isEmpty {
            startupLivePolicy = .capacityRamp(liveIDs: stalledStartupRescueLiveIDs)
        } else if startupCoverageActive {
            startupLivePolicy = .firstImage(
                allowWiredFallback: allWiredSnapshotPathsAttempted && !hasActiveSnapshotRequest
            )
        } else {
            startupLivePolicy = .normal
        }

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

        let desiredLiveIDs = Set(currentRecoveryPlan.decisionsByID.compactMap { id, decision in
            decision.presentationMode == .live ? id : nil
        })
        let activeTransportIDs = Set(feeds.compactMap { feed in
            feed.hasActiveLiveTransport ? feed.id : nil
        })
        let liveTransition = LivePlanTransitionPolicy.makeTransition(
            activeTransportIDs: activeTransportIDs,
            desiredLiveIDs: desiredLiveIDs
        )
        recordLivePlanTransitionIfNeeded(
            liveTransition,
            activeTransportIDs: activeTransportIDs,
            desiredLiveIDs: desiredLiveIDs
        )

        for feed in feeds where isVisibleOnWall(feed) {
            guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { continue }
            feed.updatePlanningStatus(recencyTier: decision.recencyTier, recoveryPhase: decision.recoveryPhase)
            updateBatteryWakeLease(for: feed.id, decision: decision, at: now)
        }

        for feed in feeds where liveTransition.stopIDs.contains(feed.id) {
            feed.stopLiveIfNeeded()
        }

        for feed in feeds where isVisibleOnWall(feed) && !desiredLiveIDs.contains(feed.id) {
            feed.presentSnapshotIfAvailable()
        }

        if liveTransition.stopIDs.isEmpty {
            for feed in feeds where desiredLiveIDs.contains(feed.id) && isVisibleOnWall(feed) {
                guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { continue }
                markStartupLiveFallbackIfNeeded(for: feed.id, decision: decision, at: now)
                feed.preferLive(at: now, liveStartTimeout: batteryWakeLiveStartTimeout)
            }
        }

        for feed in feeds where desiredLiveIDs.contains(feed.id) && isVisibleOnWall(feed) {
            updateBatteryCaptureTrust(for: feed.id, at: now)
        }

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

        serviceSnapshotQueue()
    }

    private func activateStalledStartupRescueIfNeeded(
        from planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) {
        guard stalledStartupRescueLiveIDs == nil,
              startupLiveRampState == nil,
              sessionMode == .optimistic else { return }

        let batteryProbeIDs = planningSnapshots.filter {
            $0.isBatteryWakeCamera
                && $0.hasActiveBatteryCapture(
                    at: now,
                    leaseDuration: batteryWakeLeaseDuration,
                    warmup: batteryCaptureWarmup,
                    liveStartTimeout: batteryWakeLiveStartTimeout
                )
        }.map(\.id)
        let eligibleWiredIDs = planningSnapshots.filter {
            !$0.isBatteryWakeCamera
                && !$0.hasTrustedImage(at: now)
                && $0.startupState.resolution == .pending
                && !$0.startupState.liveAttempted
        }.sorted { $0.priorityIndex < $1.priorityIndex }.map(\.id)
        let rescueID = StalledStartupRescuePolicy.rescueCandidateID(
            networkClass: sessionNetworkClass,
            startupCoverageActive: startupCoverageActive,
            rescueAlreadyAttempted: stalledStartupRescueAttempted,
            sessionElapsed: elapsedSinceSession(now),
            stallThreshold: snapshotRequestTimeout,
            hasAnyTrustedImage: planningSnapshots.contains { $0.hasTrustedImage(at: now) },
            hasPendingBatteryProbe: !batteryProbeIDs.isEmpty,
            eligibleWiredIDs: eligibleWiredIDs
        )
        guard let rescueID else { return }

        stalledStartupRescueAttempted = true
        stalledStartupRescueLiveIDs = Set(batteryProbeIDs + [rescueID])
        recordTelemetry(
            "cellular stalled-start rescue admitted \(rescueID) alongside=\(batteryProbeIDs.sorted().joined(separator: ","))"
        )
    }

    private func recordLivePlanTransitionIfNeeded(
        _ transition: LivePlanTransition,
        activeTransportIDs: Set<String>,
        desiredLiveIDs: Set<String>
    ) {
        let signature = [
            "desired=\(desiredLiveIDs.sorted().joined(separator: ","))",
            "active=\(activeTransportIDs.sorted().joined(separator: ","))",
            "stop=\(transition.stopIDs.sorted().joined(separator: ","))",
            "start=\(transition.startIDs.sorted().joined(separator: ","))",
            "deferred=\(transition.deferredStartIDs.sorted().joined(separator: ","))",
            "capacity=\(liveCapacity)"
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

            if let fallbackStartedAt = state.startupState.liveFallbackStartedAt,
               !feed.isStreaming,
               now.timeIntervalSince(fallbackStartedAt) >= batteryWakeLiveStartTimeout {
                applyStartupEvent(.liveFailed, feedID: feed.id, state: &state)
                feed.stopLiveIfNeeded()
                recordTelemetry("startup live fallback timed out \(feed.id)")
            }

            guard isVisibleOnWall(feed), preferences.isBatteryWakeCamera(id: feed.id) else {
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
            if startupCoverageActive, state.startupState.resolution == .unresolved {
                recordTelemetry(
                    "snapshot recovery released unresolved \(feedID) nextIn=\(optionalSeconds(secondsUntil(eligibleAt, from: date)))"
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
        let outstandingLimit = startupCoverageActive ? 4 : maxConcurrentSnapshotRequests
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
            applyStartupEvent(.snapshotFailed, feedID: feed.id, state: &state)
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
        if state.startupState.resolution == .unresolved {
            return "unresolvedRecovery"
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
           previousResolution != .unresolved,
           state.startupState.resolution == .unresolved {
            telemetryStartupMilestones.recordStartupUnresolved(feedID: feedID)
        }
    }

    private func handleSnapshotFailure(for feedID: String, at date: Date) {
        guard var state = feedScheduleStates[feedID] else { return }
        let priority = state.snapshotWorkState.pendingRequest?.priority
            ?? currentRecoveryPlan.decisionsByID[feedID]?.snapshotPriority
            ?? .refresh
        state.lastSnapshotFailureAt = date
        applyStartupEvent(.snapshotFailed, feedID: feedID, state: &state)
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

            applyStartupEvent(.snapshotFailed, feedID: feedID, state: &state)
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

    private func effectiveStillDate(for feed: CameraFeedCoordinator, state: FeedScheduleState?) -> Date? {
        if feed.isBatteryWakeCamera {
            guard feed.cameraSource != nil else { return nil }
            return feed.displayedStillDate
        }
        return feed.displayedStillDate ?? state?.lastSnapshotSuccessAt
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
                previousCapacity: liveCapacity,
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

        let unresolvedIDs = planningSnapshots.compactMap { snapshot -> String? in
            feedScheduleStates[snapshot.id]?.startupState.resolution == .unresolved
                ? snapshot.id
                : nil
        }
        let isComplete = planningSnapshots.allSatisfy {
            feedScheduleStates[$0.id]?.startupState.resolution != .pending
        }
        guard isComplete else { return }

        startupCoverageActive = false
        telemetryStartupMilestones.recordStartupCoverageEnded(
            unresolvedFeedIDs: unresolvedIDs,
            at: elapsedSinceSession(now)
        )
        recordTelemetry(
            "startup coverage ended unresolved=\(unresolvedIDs.isEmpty ? "none" : unresolvedIDs.joined(separator: ","))"
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

    private func markStartupLiveFallbackIfNeeded(
        for feedID: String,
        decision: PresentationDecision,
        at now: Date
    ) {
        guard startupCoverageActive,
              feedID != focusedFeedID,
              !preferences.isBatteryWakeCamera(id: feedID),
              decision.presentationMode == .live,
              var state = feedScheduleStates[feedID],
              state.startupState.resolution == .pending,
              state.startupState.liveFallbackStartedAt == nil else { return }

        applyStartupEvent(.liveRequested(at: now), feedID: feedID, state: &state)
        feedScheduleStates[feedID] = state
        telemetryStartupMilestones.recordStartupLiveFallback(feedID: feedID, at: elapsedSinceSession(now))
        recordTelemetry("startup live fallback started \(feedID)")
    }

    private func handleLiveTransportEvent(for feedID: String, event: CameraLiveTransportEvent) {
        switch event {
        case .startRequested(let requestedAt, let restarted):
            recordTelemetry(
                "live start requested \(feedID) restarted=\(restarted)",
                at: requestedAt
            )
        case .started(let startedAt, let callbackLatency):
            let startedAtElapsed = elapsedSinceSession(startedAt)
            let burstOwnsLiveSelection = wifiLiveBurstState.map { state in
                switch state.mode {
                case .headStart, .active, .batteryGrace, .completed: true
                case .inactive, .closed: false
                }
            } ?? false
            if sessionMode == .optimistic, !burstOwnsLiveSelection {
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
            if var state = feedScheduleStates[feedID], startupCoverageActive {
                applyStartupEvent(
                    burstOwnsLiveSelection ? .plainLiveStarted : .liveStarted,
                    feedID: feedID,
                    state: &state
                )
                feedScheduleStates[feedID] = state
            }
            stalledStartupRescueLiveIDs = nil
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
        case .stopRequested(let requestedAt):
            recordTelemetry("live stop requested \(feedID)", at: requestedAt)
        case .stopped(let stoppedAt, let reason, let callbackLatency):
            telemetryStartupMilestones.recordLiveStopped(
                feedID: feedID,
                callbackLatency: callbackLatency
            )
            if stalledStartupRescueLiveIDs?.contains(feedID) == true {
                stalledStartupRescueLiveIDs = nil
            }
            if reason.shouldFailStartupPath,
               var state = feedScheduleStates[feedID],
               startupCoverageActive {
                let isBatteryCamera = preferences.isBatteryWakeCamera(id: feedID)
                if startupLiveRampState != nil || state.startupState.liveAttempted || isBatteryCamera {
                    applyStartupEvent(.liveFailed, feedID: feedID, state: &state)
                }
                feedScheduleStates[feedID] = state
            }
            if reason.shouldFailStartupPath, var ramp = startupLiveRampState {
                ramp.recordLiveStopped(
                    feedID: feedID,
                    at: stoppedAt,
                    isCapacitySignal: reason.isCapacityConstrained,
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
                if reason.isCapacityConstrained {
                    burst.recordCapacityRejection(streamingIDs: streamingIDs, at: stoppedAt)
                } else if reason.shouldFailStartupPath {
                    burst.recordFailure(streamingIDs: streamingIDs, at: stoppedAt)
                }
                wifiLiveBurstState = burst
                if reason.shouldFailStartupPath, !reason.isCapacityConstrained {
                    recordTelemetry(
                        "wifi live burst closed reason=\(wifiLiveBurstModeLabel)",
                        at: stoppedAt
                    )
                    enterConstrainedAfterWiFiBurst(at: stoppedAt)
                }
            }
            recordTelemetry(
                "live stopped \(feedID) reason=\(liveStopReasonLabel(reason)) callbackLatency=\(optionalSeconds(callbackLatency)) error=\(transportErrorLabel(reason.error))",
                at: stoppedAt
            )
            if case .capacityConstrained = reason {
                handleConstrainedSignal(from: feedID)
                return
            }
        }

        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func liveStopReasonLabel(_ reason: CameraLiveStopReason) -> String {
        switch reason {
        case .requested: "requested"
        case .capacityConstrained: "capacityConstrained"
        case .failure: "failure"
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
            nonBatteryTrustedCount: trustedCount,
            nonBatteryCount: nonBatterySnapshots.count
        )
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
                startupLiveFallbackAge: age(of: state?.startupState.liveFallbackStartedAt, at: now),
                batteryStillAge: age(of: feed.batteryStillDate, at: now),
                batteryWakeLeaseAge: age(of: state?.batteryWakeLeaseStartedAt, at: now),
                batteryWakeRetryIn: secondsUntil(state?.batteryWakeRetryAfter, from: now),
                consecutiveBatteryWakeFailures: state?.consecutiveBatteryWakeFailures ?? 0,
                liveStartedAge: age(of: feed.liveStartedAt, at: now),
                liveStartRequestedAge: age(of: feed.liveStartRequestedAt, at: now),
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

struct CameraTelemetryEvent: Equatable {
    let sequence: Int
    let elapsed: TimeInterval
    let message: String
}

struct CameraStartupTelemetryMilestones: Equatable {
    var enteredConstrainedModeAt: TimeInterval?
    var enteredConstrainedModeLiveCapacity: Int?
    var firstConstrainedSignalAt: TimeInterval?
    var firstConstrainedSignalFeedID: String?
    var allVisibleFeedsTrustedAt: TimeInterval?
    var allVisibleFeedsLiveAt: TimeInterval?
    var startupCoverageEndedAt: TimeInterval?
    var startupCoverageResult: String?
    var unresolvedFeedIDs: [String] = []
    var peakActiveSnapshotRequests = 0
    var peakOutstandingSnapshotRequests = 0
    var feedsByID: [String: CameraStartupTelemetryFeedMilestones] = [:]

    mutating func recordEnteredConstrainedMode(liveCapacity: Int, at elapsed: TimeInterval) {
        guard enteredConstrainedModeAt == nil else { return }

        enteredConstrainedModeAt = elapsed
        enteredConstrainedModeLiveCapacity = liveCapacity
    }

    mutating func recordConstrainedSignal(feedID: String, at elapsed: TimeInterval) {
        guard firstConstrainedSignalAt == nil else { return }

        firstConstrainedSignalAt = elapsed
        firstConstrainedSignalFeedID = feedID
    }

    mutating func recordAllVisibleFeedsTrusted(at elapsed: TimeInterval) {
        if allVisibleFeedsTrustedAt == nil {
            allVisibleFeedsTrustedAt = elapsed
        }
    }

    mutating func recordAllVisibleFeedsLive(at elapsed: TimeInterval) {
        if allVisibleFeedsLiveAt == nil {
            allVisibleFeedsLiveAt = elapsed
        }
    }

    mutating func recordTrustedImage(feedID: String, source: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordTrustedImage(source: source, at: elapsed) }
    }

    mutating func recordSnapshotQueued(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotQueued(at: elapsed) }
    }

    mutating func recordSnapshotIssued(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotIssued(at: elapsed) }
    }

    mutating func recordSnapshotSuccess(
        feedID: String,
        callbackLatency: TimeInterval?,
        at elapsed: TimeInterval
    ) {
        updateFeed(feedID) { $0.recordSnapshotSuccess(callbackLatency: callbackLatency, at: elapsed) }
    }

    mutating func recordSnapshotFailure(
        feedID: String,
        callbackLatency: TimeInterval?,
        phase: String,
        at elapsed: TimeInterval
    ) {
        updateFeed(feedID) {
            $0.recordSnapshotFailure(callbackLatency: callbackLatency, phase: phase)
        }
    }

    mutating func recordLiveStarted(
        feedID: String,
        callbackLatency: TimeInterval?,
        resolvesTrustedImage: Bool,
        at elapsed: TimeInterval
    ) {
        updateFeed(feedID) {
            $0.recordLiveStarted(
                callbackLatency: callbackLatency,
                resolvesTrustedImage: resolvesTrustedImage,
                at: elapsed
            )
        }
    }

    mutating func recordLiveStopped(feedID: String, callbackLatency: TimeInterval?) {
        updateFeed(feedID) { $0.lastLiveStopCallbackLatency = callbackLatency }
    }

    mutating func recordSnapshotTimeout(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotTimeout() }
    }

    mutating func recordBatteryWakeLeaseStarted(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryWakeLeaseStarted(at: elapsed) }
    }

    mutating func recordBatteryTrustedStill(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryTrustedStill(at: elapsed) }
    }

    mutating func recordBatteryWakeFailure(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryWakeFailure() }
    }

    mutating func recordBatteryWakeTimeout(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryWakeTimeout() }
    }

    mutating func recordSnapshotConcurrency(active: Int, outstanding: Int) {
        peakActiveSnapshotRequests = max(peakActiveSnapshotRequests, active)
        peakOutstandingSnapshotRequests = max(peakOutstandingSnapshotRequests, outstanding)
    }

    mutating func recordStartupLiveFallback(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordStartupLiveFallback(at: elapsed) }
    }

    mutating func recordStartupUnresolved(feedID: String) {
        updateFeed(feedID) { $0.startupResolvedAsUnresolved = true }
    }

    mutating func recordStartupCoverageEnded(unresolvedFeedIDs: [String], at elapsed: TimeInterval) {
        guard startupCoverageEndedAt == nil else { return }
        startupCoverageEndedAt = elapsed
        self.unresolvedFeedIDs = unresolvedFeedIDs.sorted()
        startupCoverageResult = unresolvedFeedIDs.isEmpty ? "allTrusted" : "completedWithUnresolved"
    }

    private mutating func updateFeed(
        _ feedID: String,
        _ update: (inout CameraStartupTelemetryFeedMilestones) -> Void
    ) {
        var milestones = feedsByID[feedID] ?? CameraStartupTelemetryFeedMilestones(feedID: feedID)
        update(&milestones)
        feedsByID[feedID] = milestones
    }
}

struct CameraStartupTelemetryFeedMilestones: Equatable {
    let feedID: String
    var firstTrustedImageAt: TimeInterval?
    var firstTrustedImageSource: String?
    var firstFreshImageAt: TimeInterval?
    var firstSnapshotQueuedAt: TimeInterval?
    var firstSnapshotIssuedAt: TimeInterval?
    var firstSnapshotSuccessAt: TimeInterval?
    var lastSnapshotSuccessAt: TimeInterval?
    var snapshotQueuedCount = 0
    var snapshotIssuedCount = 0
    var snapshotSuccessCount = 0
    var snapshotFailureCount = 0
    var snapshotInitialFailureCount = 0
    var snapshotRecoveryFailureCount = 0
    var snapshotRoutineFailureCount = 0
    var snapshotTimeoutCount = 0
    var lastSnapshotCallbackLatency: TimeInterval?
    var lastLiveStartCallbackLatency: TimeInterval?
    var lastLiveStopCallbackLatency: TimeInterval?
    var firstStartupLiveFallbackAt: TimeInterval?
    var startupResolvedAsUnresolved = false
    var firstBatteryWakeLeaseStartedAt: TimeInterval?
    var firstBatteryTrustedStillAt: TimeInterval?
    var batteryWakeLeaseStartedCount = 0
    var batteryTrustedStillCount = 0
    var batteryWakeFailureCount = 0
    var batteryWakeTimeoutCount = 0

    mutating func recordTrustedImage(source: String, at elapsed: TimeInterval) {
        if firstTrustedImageAt == nil {
            firstTrustedImageAt = elapsed
            firstTrustedImageSource = source
        }
    }

    mutating func recordFreshImage(
        source: String,
        resolvesTrustedImage: Bool,
        at elapsed: TimeInterval
    ) {
        if firstFreshImageAt == nil {
            firstFreshImageAt = elapsed
        }
        if resolvesTrustedImage {
            recordTrustedImage(source: source, at: elapsed)
        }
    }

    mutating func recordSnapshotQueued(at elapsed: TimeInterval) {
        snapshotQueuedCount += 1
        if firstSnapshotQueuedAt == nil {
            firstSnapshotQueuedAt = elapsed
        }
    }

    mutating func recordSnapshotIssued(at elapsed: TimeInterval) {
        snapshotIssuedCount += 1
        if firstSnapshotIssuedAt == nil {
            firstSnapshotIssuedAt = elapsed
        }
    }

    mutating func recordSnapshotSuccess(callbackLatency: TimeInterval?, at elapsed: TimeInterval) {
        snapshotSuccessCount += 1
        lastSnapshotSuccessAt = elapsed
        lastSnapshotCallbackLatency = callbackLatency
        if firstSnapshotSuccessAt == nil {
            firstSnapshotSuccessAt = elapsed
        }
        recordFreshImage(source: "snapshot", resolvesTrustedImage: true, at: elapsed)
    }

    mutating func recordSnapshotFailure(callbackLatency: TimeInterval?, phase: String) {
        snapshotFailureCount += 1
        lastSnapshotCallbackLatency = callbackLatency
        switch phase {
        case "initialStartup": snapshotInitialFailureCount += 1
        case "unresolvedRecovery": snapshotRecoveryFailureCount += 1
        default: snapshotRoutineFailureCount += 1
        }
    }

    mutating func recordLiveStarted(
        callbackLatency: TimeInterval?,
        resolvesTrustedImage: Bool,
        at elapsed: TimeInterval
    ) {
        lastLiveStartCallbackLatency = callbackLatency
        recordFreshImage(
            source: "live",
            resolvesTrustedImage: resolvesTrustedImage,
            at: elapsed
        )
    }

    mutating func recordSnapshotTimeout() {
        snapshotTimeoutCount += 1
    }

    mutating func recordBatteryWakeLeaseStarted(at elapsed: TimeInterval) {
        batteryWakeLeaseStartedCount += 1
        if firstBatteryWakeLeaseStartedAt == nil {
            firstBatteryWakeLeaseStartedAt = elapsed
        }
    }

    mutating func recordBatteryTrustedStill(at elapsed: TimeInterval) {
        batteryTrustedStillCount += 1
        if firstBatteryTrustedStillAt == nil {
            firstBatteryTrustedStillAt = elapsed
        }
        recordFreshImage(source: "batteryStill", resolvesTrustedImage: true, at: elapsed)
    }

    mutating func recordBatteryWakeFailure() {
        batteryWakeFailureCount += 1
    }

    mutating func recordBatteryWakeTimeout() {
        batteryWakeTimeoutCount += 1
    }

    mutating func recordStartupLiveFallback(at elapsed: TimeInterval) {
        if firstStartupLiveFallbackAt == nil {
            firstStartupLiveFallbackAt = elapsed
        }
    }
}

struct CameraTelemetryFeed: Equatable {
    let priorityIndex: Int
    let id: String
    let name: String
    let roomName: String?
    let isVisibleOnWall: Bool
    let isReachable: Bool
    let isAvailableInSession: Bool
    let isHomeKitCameraActive: Bool?
    let isBatteryWakeCamera: Bool
    let isStreaming: Bool
    let isStartingLive: Bool
    let displayState: String
    let recencyTier: String
    let recoveryPhase: String
    let snapshotPriority: String
    let presentationMode: String
    let displayedStillAge: TimeInterval?
    let lastSnapshotSuccessAge: TimeInterval?
    let snapshotWorkState: String
    let snapshotRequestID: String?
    let snapshotInFlightAge: TimeInterval?
    let snapshotOverdueAge: TimeInterval?
    let nextEligibleSnapshotIn: TimeInterval?
    let lastSnapshotRequestAge: TimeInterval?
    let startupCoverageResolution: String
    let startupSnapshotAttempted: Bool
    let startupSnapshotPath: String
    let startupLivePath: String
    let startupLiveFallbackAge: TimeInterval?
    let batteryStillAge: TimeInterval?
    let batteryWakeLeaseAge: TimeInterval?
    let batteryWakeRetryIn: TimeInterval?
    let consecutiveBatteryWakeFailures: Int
    let liveStartedAge: TimeInterval?
    let liveStartRequestedAge: TimeInterval?
    let lastErrorMessage: String?
}

struct CameraTelemetryReport: Equatable {
    let generatedAt: Date
    let sessionStartedAt: Date
    let appVersion: String
    let authorizationStatus: String
    let selectedHomeName: String?
    let homeHubState: String
    let sessionMode: String
    let isAppActive: Bool
    let focusedFeedID: String?
    let liveCapacity: Int
    let visibleFeedCount: Int
    let internalMaxConcurrentSnapshotRequests: Int
    let effectiveMaxConcurrentSnapshotRequests: Int
    let snapshotRequestTimeout: TimeInterval
    let untrustedSnapshotRefreshInterval: TimeInterval
    let trustedSnapshotRefreshInterval: TimeInterval
    let batteryCaptureWarmup: TimeInterval
    let batteryWakeLeaseDuration: TimeInterval
    let batteryWakeLiveStartTimeout: TimeInterval
    let startupCoverageActive: Bool
    let sessionNetworkClass: String
    let currentNetworkClass: String
    let wifiLiveBurstMode: String
    let wifiLiveBurstSurvivorIDs: [String]
    let startupLiveRampMode: String
    let startupLiveRampSelectedIDs: [String]
    let startupLiveRampPendingIDs: [String]
    let startupLiveRampMaxPendingCount: Int
    let startupLiveRampFastThreshold: TimeInterval
    let activeSnapshotRequests: Int
    let outstandingSnapshotRequests: Int
    let liveCapacityExpansionBlockedUntil: Date?
    let liveCapacityIncludesUnconfirmedMemory: Bool
    let startupMilestones: CameraStartupTelemetryMilestones
    let feeds: [CameraTelemetryFeed]
    let events: [CameraTelemetryEvent]

    var text: String {
        var lines: [String] = []
        lines.append("Observe Telemetry")
        lines.append("generatedAt=\(generatedAt.timeIntervalSinceReferenceDate)")
        lines.append("sessionElapsed=\(formatSeconds(generatedAt.timeIntervalSince(sessionStartedAt)))")
        lines.append("appVersion=\(appVersion)")
        lines.append("authorizationStatus=\(authorizationStatus)")
        lines.append("selectedHome=\(selectedHomeName ?? "nil")")
        lines.append("homeHubState=\(homeHubState)")
        lines.append("sessionMode=\(sessionMode)")
        lines.append("isAppActive=\(isAppActive)")
        lines.append("focusedFeedID=\(focusedFeedID ?? "nil")")
        lines.append("liveCapacity=\(liveCapacity)")
        lines.append("visibleFeedCount=\(visibleFeedCount)")
        lines.append("internalMaxConcurrentSnapshotRequests=\(internalMaxConcurrentSnapshotRequests)")
        lines.append("effectiveMaxConcurrentSnapshotRequests=\(effectiveMaxConcurrentSnapshotRequests)")
        lines.append("snapshotRequestTimeout=\(formatSeconds(snapshotRequestTimeout))")
        lines.append("untrustedSnapshotRefreshInterval=\(formatSeconds(untrustedSnapshotRefreshInterval))")
        lines.append("trustedSnapshotRefreshInterval=\(formatSeconds(trustedSnapshotRefreshInterval))")
        lines.append("batteryCaptureWarmup=\(formatSeconds(batteryCaptureWarmup))")
        lines.append("batteryWakeLeaseDuration=\(formatSeconds(batteryWakeLeaseDuration))")
        lines.append("batteryWakeLiveStartTimeout=\(formatSeconds(batteryWakeLiveStartTimeout))")
        lines.append("startupCoverageActive=\(startupCoverageActive)")
        lines.append("sessionNetworkClass=\(sessionNetworkClass)")
        lines.append("currentNetworkClass=\(currentNetworkClass)")
        lines.append("wifiLiveBurstMode=\(wifiLiveBurstMode)")
        lines.append("wifiLiveBurstSurvivorIDs=\(wifiLiveBurstSurvivorIDs.isEmpty ? "none" : wifiLiveBurstSurvivorIDs.joined(separator: ","))")
        lines.append("startupLiveRampMode=\(startupLiveRampMode)")
        lines.append("startupLiveRampSelectedIDs=\(startupLiveRampSelectedIDs.isEmpty ? "none" : startupLiveRampSelectedIDs.joined(separator: ","))")
        lines.append("startupLiveRampPendingIDs=\(startupLiveRampPendingIDs.isEmpty ? "none" : startupLiveRampPendingIDs.joined(separator: ","))")
        lines.append("startupLiveRampMaxPendingCount=\(startupLiveRampMaxPendingCount)")
        lines.append("startupLiveRampFastThreshold=\(formatSeconds(startupLiveRampFastThreshold))")
        lines.append("activeSnapshotRequests=\(activeSnapshotRequests)")
        lines.append("outstandingSnapshotRequests=\(outstandingSnapshotRequests)")
        lines.append("liveCapacityExpansionBlockedFor=\(dateDelta(liveCapacityExpansionBlockedUntil, from: generatedAt))")
        lines.append("liveCapacityIncludesUnconfirmedMemory=\(liveCapacityIncludesUnconfirmedMemory)")
        lines.append("")
        lines.append("Startup Milestones")
        lines.append("enteredConstrainedModeAt=\(optionalSeconds(startupMilestones.enteredConstrainedModeAt))")
        lines.append("enteredConstrainedModeLiveCapacity=\(startupMilestones.enteredConstrainedModeLiveCapacity.map(String.init) ?? "nil")")
        lines.append("firstConstrainedSignalAt=\(optionalSeconds(startupMilestones.firstConstrainedSignalAt))")
        lines.append("firstConstrainedSignalFeedID=\(startupMilestones.firstConstrainedSignalFeedID ?? "nil")")
        lines.append("allVisibleFeedsTrustedAt=\(optionalSeconds(startupMilestones.allVisibleFeedsTrustedAt))")
        lines.append("allVisibleFeedsLiveAt=\(optionalSeconds(startupMilestones.allVisibleFeedsLiveAt))")
        lines.append("startupCoverageEndedAt=\(optionalSeconds(startupMilestones.startupCoverageEndedAt))")
        lines.append("startupCoverageResult=\(startupMilestones.startupCoverageResult ?? "nil")")
        lines.append("unresolvedFeedIDs=\(startupMilestones.unresolvedFeedIDs.isEmpty ? "none" : startupMilestones.unresolvedFeedIDs.joined(separator: ","))")
        lines.append("peakActiveSnapshotRequests=\(startupMilestones.peakActiveSnapshotRequests)")
        lines.append("peakOutstandingSnapshotRequests=\(startupMilestones.peakOutstandingSnapshotRequests)")
        lines.append("")
        lines.append("Startup Feed Milestones")
        let feedMilestones = startupMilestones.feedsByID.values.sorted { $0.feedID < $1.feedID }
        if feedMilestones.isEmpty {
            lines.append("none")
        } else {
            for milestones in feedMilestones {
                lines.append(feedMilestoneLine(milestones))
            }
        }
        lines.append("")
        lines.append("Feeds")
        for feed in feeds {
            lines.append(feedLine(feed))
        }
        lines.append("")
        lines.append("Events")
        if events.isEmpty {
            lines.append("none")
        } else {
            lines.append(contentsOf: events.map {
                "#\($0.sequence) +\(formatPreciseSeconds($0.elapsed)) \($0.message)"
            })
        }
        return lines.joined(separator: "\n")
    }

    private func feedMilestoneLine(_ milestones: CameraStartupTelemetryFeedMilestones) -> String {
        [
            milestones.feedID,
            "firstTrustedImageAt=\(optionalSeconds(milestones.firstTrustedImageAt))",
            "firstTrustedImageSource=\(milestones.firstTrustedImageSource ?? "nil")",
            "firstFreshImageAt=\(optionalSeconds(milestones.firstFreshImageAt))",
            "firstSnapshotQueuedAt=\(optionalSeconds(milestones.firstSnapshotQueuedAt))",
            "firstSnapshotIssuedAt=\(optionalSeconds(milestones.firstSnapshotIssuedAt))",
            "firstSnapshotSuccessAt=\(optionalSeconds(milestones.firstSnapshotSuccessAt))",
            "lastSnapshotSuccessAt=\(optionalSeconds(milestones.lastSnapshotSuccessAt))",
            "snapshotQueuedCount=\(milestones.snapshotQueuedCount)",
            "snapshotIssuedCount=\(milestones.snapshotIssuedCount)",
            "snapshotSuccessCount=\(milestones.snapshotSuccessCount)",
            "snapshotFailureCount=\(milestones.snapshotFailureCount)",
            "snapshotInitialFailureCount=\(milestones.snapshotInitialFailureCount)",
            "snapshotRecoveryFailureCount=\(milestones.snapshotRecoveryFailureCount)",
            "snapshotRoutineFailureCount=\(milestones.snapshotRoutineFailureCount)",
            "snapshotTimeoutCount=\(milestones.snapshotTimeoutCount)",
            "lastSnapshotCallbackLatency=\(optionalSeconds(milestones.lastSnapshotCallbackLatency))",
            "lastLiveStartCallbackLatency=\(optionalSeconds(milestones.lastLiveStartCallbackLatency))",
            "lastLiveStopCallbackLatency=\(optionalSeconds(milestones.lastLiveStopCallbackLatency))",
            "firstStartupLiveFallbackAt=\(optionalSeconds(milestones.firstStartupLiveFallbackAt))",
            "startupResolvedAsUnresolved=\(milestones.startupResolvedAsUnresolved)",
            "firstBatteryWakeLeaseStartedAt=\(optionalSeconds(milestones.firstBatteryWakeLeaseStartedAt))",
            "firstBatteryTrustedStillAt=\(optionalSeconds(milestones.firstBatteryTrustedStillAt))",
            "batteryWakeLeaseStartedCount=\(milestones.batteryWakeLeaseStartedCount)",
            "batteryTrustedStillCount=\(milestones.batteryTrustedStillCount)",
            "batteryWakeFailureCount=\(milestones.batteryWakeFailureCount)",
            "batteryWakeTimeoutCount=\(milestones.batteryWakeTimeoutCount)"
        ].joined(separator: " | ")
    }

    private func feedLine(_ feed: CameraTelemetryFeed) -> String {
        [
            "#\(feed.priorityIndex)",
            "\(feed.id) | \(feed.name) | room=\(feed.roomName ?? "nil")",
            "visible=\(feed.isVisibleOnWall)",
            "reachable=\(feed.isReachable)",
            "sessionAvailable=\(feed.isAvailableInSession)",
            "homeKitActive=\(feed.isHomeKitCameraActive.map(String.init) ?? "nil")",
            "battery=\(feed.isBatteryWakeCamera)",
            "streaming=\(feed.isStreaming)",
            "startingLive=\(feed.isStartingLive)",
            "displayState=\(feed.displayState)",
            "recency=\(feed.recencyTier)",
            "recovery=\(feed.recoveryPhase)",
            "snapshotPriority=\(feed.snapshotPriority)",
            "presentation=\(feed.presentationMode)",
            "displayedStillAge=\(optionalSeconds(feed.displayedStillAge))",
            "lastSnapshotSuccessAge=\(optionalSeconds(feed.lastSnapshotSuccessAge))",
            "snapshotWorkState=\(feed.snapshotWorkState)",
            "snapshotRequestID=\(feed.snapshotRequestID ?? "nil")",
            "snapshotInFlightAge=\(optionalSeconds(feed.snapshotInFlightAge))",
            "snapshotOverdueAge=\(optionalSeconds(feed.snapshotOverdueAge))",
            "nextEligibleSnapshotIn=\(optionalSeconds(feed.nextEligibleSnapshotIn))",
            "lastSnapshotRequestAge=\(optionalSeconds(feed.lastSnapshotRequestAge))",
            "startupCoverage=\(feed.startupCoverageResolution)",
            "startupSnapshotAttempted=\(feed.startupSnapshotAttempted)",
            "startupSnapshotPath=\(feed.startupSnapshotPath)",
            "startupLivePath=\(feed.startupLivePath)",
            "startupLiveFallbackAge=\(optionalSeconds(feed.startupLiveFallbackAge))",
            "batteryStillAge=\(optionalSeconds(feed.batteryStillAge))",
            "batteryWakeLeaseAge=\(optionalSeconds(feed.batteryWakeLeaseAge))",
            "batteryWakeRetryIn=\(optionalSeconds(feed.batteryWakeRetryIn))",
            "batteryWakeFailures=\(feed.consecutiveBatteryWakeFailures)",
            "liveStartedAge=\(optionalSeconds(feed.liveStartedAge))",
            "liveStartRequestedAge=\(optionalSeconds(feed.liveStartRequestedAge))",
            "lastError=\(feed.lastErrorMessage ?? "nil")"
        ].joined(separator: " | ")
    }

    private func dateDelta(_ date: Date?, from reference: Date) -> String {
        guard let date else { return "nil" }
        return formatSeconds(date.timeIntervalSince(reference))
    }

    private func ageLine(_ date: Date?, at reference: Date) -> String {
        guard let date else { return "nil" }
        return formatSeconds(max(0, reference.timeIntervalSince(date)))
    }
}

private func age(of date: Date?, at reference: Date) -> TimeInterval? {
    guard let date else { return nil }
    return max(0, reference.timeIntervalSince(date))
}

private func secondsUntil(_ date: Date?, from reference: Date) -> TimeInterval? {
    guard let date, date != .distantPast, date != .distantFuture else { return nil }
    return date.timeIntervalSince(reference)
}

private func optionalSeconds(_ value: TimeInterval?) -> String {
    guard let value else { return "nil" }
    return formatSeconds(value)
}

private func formatSeconds(_ value: TimeInterval) -> String {
    String(format: "%.1fs", value)
}

private func formatPreciseSeconds(_ value: TimeInterval) -> String {
    String(format: "%.3fs", value)
}

private func transportErrorLabel(_ error: CameraTransportError?) -> String {
    guard let error else { return "nil" }
    return "\(error.domain):\(error.code) \(error.message)"
}

private func snapshotWorkStateLabel(_ state: SnapshotWorkState?) -> String {
    guard let state else { return "unknown" }
    switch state {
    case .idle:
        return "idle"
    case .queued:
        return "queued"
    case .pending(let request):
        return request.timeoutReportedAt == nil ? "active" : "overdue"
    }
}

enum SnapshotQueuePolicy {
    static func minimumRefreshInterval(for priority: SnapshotPriority) -> TimeInterval {
        switch priority {
        case .urgent:
            CameraSchedulingDefaults.untrustedSnapshotRefreshInterval
        case .refresh, .none:
            CameraSchedulingDefaults.minimumSnapshotRefreshInterval
        }
    }

    static func nextEligibleDate(current: Date, requestedAt: Date) -> Date {
        nextEligibleDate(
            current: current,
            requestedAt: requestedAt,
            lastRequestIssuedAt: nil,
            minimumInterval: 0
        )
    }

    static func nextEligibleDate(
        current: Date,
        requestedAt: Date,
        lastRequestIssuedAt: Date?,
        minimumInterval: TimeInterval
    ) -> Date {
        let intervalEligibleDate = lastRequestIssuedAt.map {
            $0.addingTimeInterval(max(0, minimumInterval))
        } ?? requestedAt
        let requestedOrThrottledDate = max(requestedAt, intervalEligibleDate)

        if current == .distantFuture {
            return requestedOrThrottledDate
        }

        if current > requestedAt {
            return max(current, requestedOrThrottledDate)
        }

        return requestedOrThrottledDate
    }

    static func nextEligibleDateAfterFailure(
        failedAt: Date,
        lastRequestIssuedAt: Date?,
        priority: SnapshotPriority
    ) -> Date {
        let minimumInterval = minimumRefreshInterval(for: priority)
        let issueEligibleDate = lastRequestIssuedAt.map {
            $0.addingTimeInterval(max(0, minimumInterval))
        } ?? failedAt
        let completionEligibleDate = failedAt.addingTimeInterval(max(0, minimumInterval))
        return max(issueEligibleDate, completionEligibleDate)
    }
}

enum StartupSnapshotRecoveryPolicy {
    static func retryEligibleDate(
        startupCoverageActive: Bool,
        startupState: StartupCameraState,
        snapshotFailedAt: Date?,
        lastRequestIssuedAt: Date?,
        priority: SnapshotPriority
    ) -> Date? {
        guard let snapshotFailedAt else { return nil }
        guard !startupCoverageActive || startupState.resolution == .unresolved else {
            return nil
        }

        return SnapshotQueuePolicy.nextEligibleDateAfterFailure(
            failedAt: snapshotFailedAt,
            lastRequestIssuedAt: lastRequestIssuedAt,
            priority: priority
        )
    }
}

enum StartupSnapshotConcurrencyPolicy {
    static func effectiveLimit(
        isFirstFramePhaseActive: Bool,
        nonBatteryTrustedCount: Int,
        nonBatteryCount: Int
    ) -> Int {
        guard isFirstFramePhaseActive,
              nonBatteryCount > 0,
              nonBatteryTrustedCount < nonBatteryCount else {
            return CameraSchedulingDefaults.maxConcurrentSnapshotRequests
        }

        let startupLimit = nonBatteryTrustedCount == 0 ? 2 : 3
        return min(CameraSchedulingDefaults.maxConcurrentSnapshotRequests, startupLimit)
    }
}

enum SnapshotRequestMatchPolicy {
    static func isCurrent(
        currentRequestID: SnapshotRequestID?,
        resultRequestID: SnapshotRequestID?,
        isInFlight: Bool
    ) -> Bool {
        guard isInFlight,
              let currentRequestID,
              let resultRequestID else {
            return false
        }

        return currentRequestID == resultRequestID
    }

    static func acceptsLateFirstSuccess(
        result: SnapshotRequestResult,
        hasTrustedImage: Bool,
        staleThreshold: TimeInterval,
        now: Date
    ) -> Bool {
        guard !hasTrustedImage,
              case .success(let captureDate) = result else {
            return false
        }

        return max(0, now.timeIntervalSince(captureDate)) <= staleThreshold
    }
}

enum SnapshotResultTelemetry {
    static func staleSchedulerResultIgnoredMessage(
        feedID: String,
        requestID: SnapshotRequestID?,
        currentRequestID: SnapshotRequestID?,
        result: SnapshotRequestResult,
        now: Date
    ) -> String {
        let baseMessage = "snapshot stale scheduler result ignored \(feedID) request=\(requestID.map(String.init) ?? "nil") current=\(currentRequestID.map(String.init) ?? "nil")"
        switch result {
        case .success(let captureDate):
            return "\(baseMessage) imageUpdated=true captureAge=\(formatSeconds(max(0, now.timeIntervalSince(captureDate))))"
        case .failure(let error):
            return "\(baseMessage) imageUpdated=false error=\(transportErrorLabel(error))"
        }
    }
}

enum BatteryTrustedStillCapturePolicy {
    static func shouldCapture(
        isBatteryCamera: Bool,
        isStreaming: Bool,
        liveStartedAt: Date?,
        batteryStillDate: Date?,
        batteryWakeLeaseStartedAt: Date?,
        allowsUnleasedCapture: Bool,
        warmup: TimeInterval,
        now: Date
    ) -> Bool {
        guard isBatteryCamera, isStreaming, let liveStartedAt else { return false }
        guard allowsUnleasedCapture || batteryWakeLeaseStartedAt != nil else { return false }

        guard now.timeIntervalSince(liveStartedAt) >= warmup else { return false }

        return (batteryStillDate ?? .distantPast) < liveStartedAt
    }
}

enum BatteryWakeLeaseTimeoutPolicy {
    static func hasTimedOut(
        isStreaming: Bool,
        liveStartedAt: Date?,
        batteryWakeLeaseStartedAt: Date,
        warmup: TimeInterval,
        leaseDuration: TimeInterval,
        liveStartTimeout: TimeInterval,
        now: Date
    ) -> Bool {
        if isStreaming, let liveStartedAt {
            return now.timeIntervalSince(liveStartedAt) >= max(warmup, leaseDuration)
        }
        return now.timeIntervalSince(batteryWakeLeaseStartedAt) >= liveStartTimeout
    }
}

enum BatteryWakeConstrainedSignalPolicy {
    static func shouldKeepLeaseAlive(
        isBatteryCamera: Bool,
        isStreaming: Bool,
        liveStartedAt: Date?,
        batteryWakeLeaseStartedAt: Date?,
        didCaptureTrustedStill: Bool,
        warmup: TimeInterval,
        leaseDuration: TimeInterval,
        liveStartTimeout: TimeInterval,
        now: Date
    ) -> Bool {
        guard isBatteryCamera,
              isStreaming,
              liveStartedAt != nil,
              let batteryWakeLeaseStartedAt,
              !didCaptureTrustedStill else {
            return false
        }

        return !BatteryWakeLeaseTimeoutPolicy.hasTimedOut(
            isStreaming: isStreaming,
            liveStartedAt: liveStartedAt,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
            warmup: warmup,
            leaseDuration: leaseDuration,
            liveStartTimeout: liveStartTimeout,
            now: now
        )
    }
}

enum RestrictedLiveCapacity {
    static func enteringAfterConstrainedSignal(
        currentLiveCount: Int,
        visibleFeedCount: Int,
        rememberedCapacity: Int? = nil
    ) -> Int {
        boundedCapacity(
            observedLiveCount: max(currentLiveCount, rememberedCapacity ?? 0),
            visibleFeedCount: visibleFeedCount
        )
    }

    static func recordSuccessfulStreams(
        previousCapacity: Int,
        currentLiveCount: Int,
        visibleFeedCount: Int
    ) -> Int {
        boundedCapacity(
            observedLiveCount: max(previousCapacity, currentLiveCount),
            visibleFeedCount: visibleFeedCount
        )
    }

    static func planningBudget(
        knownCapacity: Int,
        visibleFeedCount: Int,
        hasBatteryCaptureDemand: Bool,
        allVisibleFeedsTrusted: Bool,
        canProbeCapacity: Bool
    ) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        let boundedKnownCapacity = boundedCapacity(
            observedLiveCount: knownCapacity,
            visibleFeedCount: visibleFeedCount
        )
        guard canProbeCapacity, allVisibleFeedsTrusted else {
            return boundedKnownCapacity
        }

        return min(visibleFeedCount, boundedKnownCapacity + 1)
    }

    static func afterConstrainedSignal(
        previousCapacity _: Int,
        currentLiveCount: Int,
        visibleFeedCount: Int
    ) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        return boundedCapacity(
            observedLiveCount: currentLiveCount,
            visibleFeedCount: visibleFeedCount
        )
    }

    private static func boundedCapacity(observedLiveCount: Int, visibleFeedCount: Int) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        return min(max(1, observedLiveCount), visibleFeedCount)
    }
}
