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
    private weak var selectedHome: HMHome?
    private var snapshotSchedulerTask: Task<Void, Never>?
    private var feedScheduleStates: [String: FeedScheduleState] = [:]
    private var currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
    private var liveCapacityExpansionBlockedUntil: Date?
    private var liveCapacityIncludesUnconfirmedMemory = false
    private var restrictedStartupSnapshotPrimingStartedAt: Date?
    private var telemetrySessionStartedAt = Date()
    private var telemetryEvents: [CameraTelemetryEvent] = []
    private var telemetryStartupMilestones = CameraStartupTelemetryMilestones()
    private var nextSnapshotRequestID: SnapshotRequestID = 1

    private let snapshotRequestTimeout = CameraSchedulingDefaults.snapshotRequestTimeout
    private let maxTelemetryEvents = 240

    private var maxConcurrentSnapshotRequests: Int {
        preferences.maxConcurrentSnapshotRequests
    }

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

    init(preferences: ObservePreferences) {
        self.preferences = preferences
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
        priorityOrderedFeeds.filter(\.isVisibleOnWall)
    }

    func setAppActive(_ active: Bool) {
        let wasActive = isAppActive
        guard wasActive != active else { return }

        isAppActive = active

        if CameraSessionActivation.shouldRebuildSession(currentlyActive: wasActive, nextActive: active) {
            focusedFeedID = nil
            rebuildHomesAndFeeds()
        } else {
            snapshotSchedulerTask?.cancel()
            focusedFeedID = nil
            liveCapacity = 0
            liveCapacityExpansionBlockedUntil = nil
            liveCapacityIncludesUnconfirmedMemory = false
            restrictedStartupSnapshotPrimingStartedAt = nil
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

    func adjustDensity(with scale: CGFloat) {
        guard CameraWallInteraction.allowsDensityAdjustment(for: .current) else { return }

        preferences.adjustDensity(with: scale)
    }

    func adjustDensity(withHorizontalSwipe translationWidth: CGFloat) {
        guard CameraWallInteraction.allowsDensityAdjustment(for: .current) else { return }

        preferences.adjustDensity(withHorizontalSwipe: translationWidth)
    }

    func telemetryReportText(at now: Date = Date()) -> String {
        CameraTelemetryReport(
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
            maxConcurrentSnapshotRequests: maxConcurrentSnapshotRequests,
            snapshotRequestTimeout: snapshotRequestTimeout,
            untrustedSnapshotRefreshInterval: CameraSchedulingDefaults.untrustedSnapshotRefreshInterval,
            trustedSnapshotRefreshInterval: CameraSchedulingDefaults.minimumSnapshotRefreshInterval,
            batteryCaptureWarmup: batteryCaptureWarmup,
            batteryWakeLeaseDuration: batteryWakeLeaseDuration,
            batteryWakeLiveStartTimeout: batteryWakeLiveStartTimeout,
            restrictedStartupSnapshotPrimingSeconds: preferences.restrictedStartupSnapshotPrimingSeconds,
            liveCapacityExpansionBlockedUntil: liveCapacityExpansionBlockedUntil,
            liveCapacityIncludesUnconfirmedMemory: liveCapacityIncludesUnconfirmedMemory,
            restrictedStartupSnapshotPrimingStartedAt: restrictedStartupSnapshotPrimingStartedAt,
            startupMilestones: telemetryStartupMilestones,
            feeds: telemetryFeeds(at: now),
            events: telemetryEvents
        ).text
    }

    private func rebuildHomesAndFeeds() {
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
            restrictedStartupSnapshotPrimingStartedAt = nil
            return
        }

        home.delegate = self

        var discoveredFeeds: [CameraFeedCoordinator] = []
        for accessory in home.accessories {
            accessory.delegate = self

            let profiles = accessory.cameraProfiles ?? []
            for (index, profile) in profiles.enumerated() {
                let feed = CameraFeedCoordinator(accessory: accessory, profile: profile, profileIndex: index)
                feed.onConstrainedSignal = { [weak self] feedID in
                    Task { @MainActor [weak self] in
                        self?.handleConstrainedSignal(from: feedID)
                    }
                }
                feed.onSnapshotResult = { [weak self] feedID, requestID, result in
                    Task { @MainActor [weak self] in
                        self?.handleSnapshotResult(for: feedID, requestID: requestID, result: result)
                    }
                }
                feed.onAvailabilityChanged = { [weak self] feedID in
                    Task { @MainActor [weak self] in
                        self?.handleAvailabilityChange(for: feedID)
                    }
                }
                feed.refreshHomeKitCameraActiveState()
                feed.readHomeKitCameraActiveState()
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
                        snapshotInFlight: false,
                        snapshotRequestStartedAt: nil,
                        snapshotRequestID: nil,
                        lastSnapshotRequestIssuedAt: nil,
                        nextEligibleSnapshotAt: .distantPast,
                        batteryWakeLeaseStartedAt: nil,
                        batteryWakeRetryAfter: nil,
                        consecutiveBatteryWakeFailures: 0,
                        lastTelemetryQueuedSnapshotPriority: nil
                    )
                )
            }
        )

        sessionMode = .optimistic
        liveCapacity = wallFeeds.count
        liveCapacityExpansionBlockedUntil = nil
        liveCapacityIncludesUnconfirmedMemory = false
        restrictedStartupSnapshotPrimingStartedAt = nil
        startSession()
    }

    private func startSession() {
        snapshotSchedulerTask?.cancel()

        guard isAppActive, !feeds.isEmpty else { return }

        telemetrySessionStartedAt = Date()
        telemetryEvents = []
        telemetryStartupMilestones = CameraStartupTelemetryMilestones()
        nextSnapshotRequestID = 1
        recordTelemetry("session start feeds=\(feeds.count) visible=\(wallFeeds.count) liveCapacity=\(liveCapacity)")
        refreshPresentation(focusedFeedID: focusedFeedID)

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
        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        let liveBudget: Int
        switch sessionMode {
        case .optimistic:
            liveBudget = planningSnapshots.count
        case .constrained:
            if currentLiveCount > 0 {
                recordRememberedRestrictedLiveCapacity(currentLiveCount, visibleFeedCount: planningSnapshots.count)
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
        let deferNewBatteryCaptureForSnapshotPriming = shouldDeferNewBatteryCaptureForSnapshotPriming(
            planningSnapshots,
            at: now
        )

        currentRecoveryPlan = CameraRecoveryPlanner(
            batteryWakeLeaseDuration: batteryWakeLeaseDuration,
            batteryCaptureWarmup: batteryCaptureWarmup,
            batteryWakeLiveStartTimeout: batteryWakeLiveStartTimeout
        ).makePlan(
            feeds: planningSnapshots,
            sessionMode: sessionMode,
            liveCapacity: liveBudget,
            deferNewBatteryCaptureForSnapshotPriming: deferNewBatteryCaptureForSnapshotPriming,
            now: now
        )

        cancelBatteryWakeLeasesSupersededByFocus(at: now)

        for feed in feeds {
            guard feed.isVisibleOnWall else {
                feed.stopLiveIfNeeded()
                continue
            }

            guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { continue }
            feed.updatePlanningStatus(recencyTier: decision.recencyTier, recoveryPhase: decision.recoveryPhase)
            updateBatteryWakeLease(for: feed.id, decision: decision, at: now)

            if decision.presentationMode == .live {
                feed.preferLive(at: now, liveStartTimeout: batteryWakeLiveStartTimeout)
                updateBatteryCaptureTrust(for: feed.id, at: now)
            } else {
                feed.stopLiveIfNeeded()
                feed.presentSnapshotIfAvailable()
            }

            if decision.snapshotPriority != .none, !feed.isStreaming {
                queueSnapshotRefresh(for: feed.id, priority: decision.snapshotPriority, at: now)
            }
        }

        serviceSnapshotQueue()
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
                batteryWakeRetryAfter: state?.batteryWakeRetryAfter
            )
        }
    }

    private func reconcileFeedScheduleStates(at now: Date, focusedFeedID: String?) {
        for feed in feeds {
            guard var state = feedScheduleStates[feed.id] else { continue }

            guard feed.isVisibleOnWall, preferences.isBatteryWakeCamera(id: feed.id) else {
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
                state = recordBatteryWakeFailure(state, at: now)
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
        state.nextEligibleSnapshotAt = .distantFuture
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
            warmup: batteryCaptureWarmup,
            now: now
        ) else {
            return
        }

        feed.markBatteryStillCaptured(at: now)
        state.batteryWakeLeaseStartedAt = nil
        state.batteryWakeRetryAfter = nil
        state.consecutiveBatteryWakeFailures = 0
        state.nextEligibleSnapshotAt = now
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
            state.nextEligibleSnapshotAt = date
        } else {
            feeds.first { $0.id == feedID }?.stopLiveIfNeeded()
            telemetryStartupMilestones.recordBatteryWakeFailure(feedID: feedID, at: elapsedSinceSession(date))
            recordTelemetry("battery wake failed \(feedID)")
            state = recordBatteryWakeFailure(state, at: date)
        }
        feedScheduleStates[feedID] = state
        return true
    }

    private func recordBatteryWakeFailure(_ state: FeedScheduleState, at date: Date) -> FeedScheduleState {
        var state = state
        state.batteryWakeLeaseStartedAt = nil
        state.consecutiveBatteryWakeFailures += 1
        state.batteryWakeRetryAfter = date.addingTimeInterval(
            batteryWakeBackoff(for: state.consecutiveBatteryWakeFailures)
        )
        state.nextEligibleSnapshotAt = date
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
        guard var state = feedScheduleStates[feedID] else { return }
        guard !state.snapshotInFlight else { return }
        let resolvedPriority = priority ?? currentRecoveryPlan.decisionsByID[feedID]?.snapshotPriority ?? .refresh
        state.nextEligibleSnapshotAt = SnapshotQueuePolicy.nextEligibleDate(
            current: state.nextEligibleSnapshotAt,
            requestedAt: date,
            lastRequestIssuedAt: state.lastSnapshotRequestIssuedAt,
            minimumInterval: SnapshotQueuePolicy.minimumRefreshInterval(for: resolvedPriority)
        )
        let shouldRecordQueueEvent = state.lastTelemetryQueuedSnapshotPriority != resolvedPriority
        state.lastTelemetryQueuedSnapshotPriority = resolvedPriority
        feedScheduleStates[feedID] = state
        telemetryStartupMilestones.recordSnapshotQueued(feedID: feedID, at: elapsedSinceSession(date))
        if shouldRecordQueueEvent {
            recordTelemetry(
                "snapshot queued \(feedID) priority=\(resolvedPriority) nextIn=\(optionalSeconds(secondsUntil(state.nextEligibleSnapshotAt, from: date)))"
            )
        }
    }

    private func serviceSnapshotQueue() {
        guard isAppActive else { return }
        let feedLookup = Dictionary(uniqueKeysWithValues: wallFeeds.map { ($0.id, $0) })
        let snapshotFeeds = currentRecoveryPlan.orderedSnapshotIDs.compactMap { feedLookup[$0] }
        let inFlightCount = feedScheduleStates.values.filter(\.snapshotInFlight).count
        var availableSlots = maxConcurrentSnapshotRequests - inFlightCount

        guard availableSlots > 0 else { return }

        let now = Date()
        let dueFeeds = snapshotFeeds
            .filter { feed in
                guard let state = feedScheduleStates[feed.id] else { return false }
                guard !state.snapshotInFlight else { return false }
                return state.nextEligibleSnapshotAt <= now
            }

        for feed in dueFeeds {
            guard availableSlots > 0 else { break }
            if issueSnapshotRequest(for: feed, at: now) {
                availableSlots -= 1
            }
        }
    }

    @discardableResult
    private func issueSnapshotRequest(for feed: CameraFeedCoordinator, at date: Date) -> Bool {
        guard var state = feedScheduleStates[feed.id] else { return false }
        guard !state.snapshotInFlight else { return false }

        let requestID = nextSnapshotRequestID
        if feed.requestSnapshot(requestID: requestID) {
            nextSnapshotRequestID += 1
            state.snapshotInFlight = true
            state.snapshotRequestStartedAt = date
            state.snapshotRequestID = requestID
            state.lastSnapshotRequestIssuedAt = date
            state.nextEligibleSnapshotAt = .distantFuture
            feedScheduleStates[feed.id] = state
            telemetryStartupMilestones.recordSnapshotIssued(feedID: feed.id, at: elapsedSinceSession(date))
            recordTelemetry("snapshot issued \(feed.id) request=\(requestID)")
            return true
        } else {
            recordTelemetry("snapshot request rejected \(feed.id)")
            handleSnapshotFailure(for: feed.id, at: date)
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
                    currentRequestID: feedScheduleStates[feedID]?.snapshotRequestID,
                    result: result,
                    now: Date()
                )
            )
            return
        }

        switch result {
        case .success(let captureDate):
            guard var state = feedScheduleStates[feedID] else { return }
            state.lastSnapshotSuccessAt = captureDate
            state.snapshotInFlight = false
            state.snapshotRequestStartedAt = nil
            state.snapshotRequestID = nil
            state.nextEligibleSnapshotAt = .distantFuture
            feedScheduleStates[feedID] = state
            telemetryStartupMilestones.recordSnapshotSuccess(feedID: feedID, at: elapsedSinceSession(Date()))
            recordTelemetry("snapshot success \(feedID) request=\(requestID.map(String.init) ?? "nil") captureAge=\(formatSeconds(max(0, Date().timeIntervalSince(captureDate))))")
        case .failure:
            telemetryStartupMilestones.recordSnapshotFailure(feedID: feedID, at: elapsedSinceSession(Date()))
            recordTelemetry("snapshot failure \(feedID) request=\(requestID.map(String.init) ?? "nil")")
            handleSnapshotFailure(for: feedID, at: Date())
        }

        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func acceptLateFirstSnapshotSuccess(
        for feedID: String,
        requestID: SnapshotRequestID?,
        result: SnapshotRequestResult,
        at now: Date
    ) -> Bool {
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
        if !state.snapshotInFlight {
            state.snapshotRequestStartedAt = nil
            state.snapshotRequestID = nil
            state.nextEligibleSnapshotAt = .distantFuture
        }
        feedScheduleStates[feedID] = state
        telemetryStartupMilestones.recordSnapshotSuccess(feedID: feedID, at: elapsedSinceSession(now))
        recordTelemetry(
            "snapshot late success accepted \(feedID) request=\(requestID.map(String.init) ?? "nil") current=\(state.snapshotRequestID.map(String.init) ?? "nil") captureAge=\(formatSeconds(max(0, now.timeIntervalSince(captureDate))))"
        )
        return true
    }

    private func isCurrentSnapshotRequest(feedID: String, requestID: SnapshotRequestID?) -> Bool {
        guard let state = feedScheduleStates[feedID] else {
            return false
        }

        return SnapshotRequestMatchPolicy.isCurrent(
            currentRequestID: state.snapshotRequestID,
            resultRequestID: requestID,
            isInFlight: state.snapshotInFlight
        )
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

    private func handleSnapshotFailure(for feedID: String, at date: Date) {
        guard var state = feedScheduleStates[feedID] else { return }
        state.snapshotInFlight = false
        state.snapshotRequestStartedAt = nil
        state.snapshotRequestID = nil
        let priority = currentRecoveryPlan.decisionsByID[feedID]?.snapshotPriority ?? .refresh
        state.nextEligibleSnapshotAt = SnapshotQueuePolicy.nextEligibleDate(
            current: date,
            requestedAt: date,
            lastRequestIssuedAt: state.lastSnapshotRequestIssuedAt,
            minimumInterval: SnapshotQueuePolicy.minimumRefreshInterval(for: priority)
        )
        feedScheduleStates[feedID] = state
    }

    private func handleSnapshotTimeouts() {
        let now = Date()

        for (feedID, state) in feedScheduleStates where state.snapshotInFlight {
            guard let snapshotRequestStartedAt = state.snapshotRequestStartedAt else { continue }
            if now.timeIntervalSince(snapshotRequestStartedAt) > snapshotRequestTimeout {
                telemetryStartupMilestones.recordSnapshotTimeout(feedID: feedID, at: elapsedSinceSession(now))
                recordTelemetry("snapshot timeout \(feedID) request=\(state.snapshotRequestID.map(String.init) ?? "nil")")
                handleSnapshotFailure(for: feedID, at: now)
            }
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

    private func shouldDeferNewBatteryCaptureForSnapshotPriming(
        _ planningSnapshots: [FeedPlanningSnapshot],
        at now: Date
    ) -> Bool {
        guard sessionMode == .constrained,
              let primingStartedAt = restrictedStartupSnapshotPrimingStartedAt else {
            return false
        }

        guard preferences.restrictedStartupSnapshotPrimingDuration > 0,
              now.timeIntervalSince(primingStartedAt) < preferences.restrictedStartupSnapshotPrimingDuration else {
            endRestrictedStartupSnapshotPriming(reason: "expired", at: now)
            return false
        }

        let shouldDefer = RestrictedStartupSnapshotPrimingPolicy.shouldDeferNewBatteryCapture(
            feeds: planningSnapshots,
            leaseDuration: batteryWakeLeaseDuration,
            warmup: batteryCaptureWarmup,
            liveStartTimeout: batteryWakeLiveStartTimeout,
            now: now
        )
        if !shouldDefer {
            endRestrictedStartupSnapshotPriming(reason: "trusted", at: now)
        }
        if shouldDefer {
            recordTelemetry("startup priming defers new battery capture")
        }
        return shouldDefer
    }

    private func handleConstrainedSignal(from feedID: String) {
        let now = Date()
        telemetryStartupMilestones.recordConstrainedSignal(feedID: feedID, at: elapsedSinceSession(now))
        recordTelemetry("constrained signal \(feedID) mode=\(sessionMode) liveCapacity=\(liveCapacity)")
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

        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        let visibleFeedCount = wallFeeds.count

        if sessionMode == .optimistic {
            let rememberedCapacity = preferences.rememberedRestrictedLiveCapacity(
                homeID: selectedHome?.uniqueIdentifier.uuidString,
                visibleCameraCount: visibleFeedCount
            )
            liveCapacity = RestrictedLiveCapacity.enteringAfterConstrainedSignal(
                currentLiveCount: currentLiveCount,
                visibleFeedCount: visibleFeedCount,
                rememberedCapacity: rememberedCapacity
            )
            liveCapacityIncludesUnconfirmedMemory = (rememberedCapacity ?? 0) > max(1, currentLiveCount)
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
              var state = feedScheduleStates[feedID],
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

        state.nextEligibleSnapshotAt = .distantFuture
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
            state.nextEligibleSnapshotAt = now
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
        restrictedStartupSnapshotPrimingStartedAt = now
        telemetryStartupMilestones.recordEnteredConstrainedMode(liveCapacity: liveCapacity, at: elapsedSinceSession(now))
        telemetryStartupMilestones.recordPrimingStarted(at: elapsedSinceSession(now))
        recordTelemetry("entered constrained mode liveCapacity=\(liveCapacity)")
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func handleAvailabilityChange(for feedID: String) {
        if focusedFeedID == feedID {
            focusedFeedID = nil
        }

        if var state = feedScheduleStates[feedID] {
            state.batteryWakeLeaseStartedAt = nil
            state.snapshotInFlight = false
            state.snapshotRequestStartedAt = nil
            state.snapshotRequestID = nil
            state.batteryWakeRetryAfter = nil
            state.consecutiveBatteryWakeFailures = 0
            state.nextEligibleSnapshotAt = .distantFuture
            feedScheduleStates[feedID] = state
        }

        let visibleCount = wallFeeds.count
        liveCapacity = min(liveCapacity, visibleCount)
        if visibleCount == 0 {
            liveCapacityExpansionBlockedUntil = nil
            liveCapacityIncludesUnconfirmedMemory = false
            restrictedStartupSnapshotPrimingStartedAt = nil
        }

        objectWillChange.send()
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func recordRememberedRestrictedLiveCapacity(_ capacity: Int, visibleFeedCount: Int) {
        preferences.recordRestrictedLiveCapacity(
            capacity,
            homeID: selectedHome?.uniqueIdentifier.uuidString,
            visibleCameraCount: visibleFeedCount
        )
    }

    private func updateTrustedImageMilestones(from planningSnapshots: [FeedPlanningSnapshot], at now: Date) {
        guard !planningSnapshots.isEmpty else { return }

        let elapsed = elapsedSinceSession(now)
        for snapshot in planningSnapshots where snapshot.hasTrustedImage(at: now) {
            telemetryStartupMilestones.recordTrustedImage(feedID: snapshot.id, at: elapsed)
        }

        if planningSnapshots.allSatisfy({ $0.hasTrustedImage(at: now) }) {
            telemetryStartupMilestones.recordAllVisibleFeedsTrusted(at: elapsed)
        }
    }

    private func endRestrictedStartupSnapshotPriming(reason: String, at now: Date) {
        guard restrictedStartupSnapshotPrimingStartedAt != nil else { return }

        restrictedStartupSnapshotPrimingStartedAt = nil
        telemetryStartupMilestones.recordPrimingEnded(reason: reason, at: elapsedSinceSession(now))
        recordTelemetry("startup priming ended reason=\(reason)")
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
                snapshotInFlightAge: age(of: state?.snapshotRequestStartedAt, at: now),
                nextEligibleSnapshotIn: secondsUntil(state?.nextEligibleSnapshotAt, from: now),
                lastSnapshotRequestAge: age(of: state?.lastSnapshotRequestIssuedAt, at: now),
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
                elapsed: max(0, date.timeIntervalSince(telemetrySessionStartedAt)),
                message: message
            )
        )
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
                state.nextEligibleSnapshotAt = .distantPast
                self.feedScheduleStates[feed.id] = state
            }

            let visibleCount = self.wallFeeds.count
            self.liveCapacity = min(self.liveCapacity, visibleCount)
            if visibleCount == 0 {
                self.liveCapacityExpansionBlockedUntil = nil
                self.liveCapacityIncludesUnconfirmedMemory = false
                self.restrictedStartupSnapshotPrimingStartedAt = nil
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
    var snapshotInFlight: Bool
    var snapshotRequestStartedAt: Date?
    var snapshotRequestID: SnapshotRequestID?
    var lastSnapshotRequestIssuedAt: Date?
    var nextEligibleSnapshotAt: Date
    var batteryWakeLeaseStartedAt: Date?
    var batteryWakeRetryAfter: Date?
    var consecutiveBatteryWakeFailures: Int
    var lastTelemetryQueuedSnapshotPriority: SnapshotPriority?
}

struct CameraTelemetryEvent: Equatable {
    let elapsed: TimeInterval
    let message: String
}

struct CameraStartupTelemetryMilestones: Equatable {
    var enteredConstrainedModeAt: TimeInterval?
    var enteredConstrainedModeLiveCapacity: Int?
    var firstConstrainedSignalAt: TimeInterval?
    var firstConstrainedSignalFeedID: String?
    var primingStartedAt: TimeInterval?
    var primingEndedAt: TimeInterval?
    var primingEndedReason: String?
    var allVisibleFeedsTrustedAt: TimeInterval?
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

    mutating func recordPrimingStarted(at elapsed: TimeInterval) {
        if primingStartedAt == nil {
            primingStartedAt = elapsed
        }
    }

    mutating func recordPrimingEnded(reason: String, at elapsed: TimeInterval) {
        guard primingEndedAt == nil else { return }

        primingEndedAt = elapsed
        primingEndedReason = reason
    }

    mutating func recordAllVisibleFeedsTrusted(at elapsed: TimeInterval) {
        if allVisibleFeedsTrustedAt == nil {
            allVisibleFeedsTrustedAt = elapsed
        }
    }

    mutating func recordTrustedImage(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordTrustedImage(at: elapsed) }
    }

    mutating func recordSnapshotQueued(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotQueued(at: elapsed) }
    }

    mutating func recordSnapshotIssued(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotIssued(at: elapsed) }
    }

    mutating func recordSnapshotSuccess(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotSuccess(at: elapsed) }
    }

    mutating func recordSnapshotFailure(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotFailure() }
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
    var firstSnapshotQueuedAt: TimeInterval?
    var firstSnapshotIssuedAt: TimeInterval?
    var firstSnapshotSuccessAt: TimeInterval?
    var lastSnapshotSuccessAt: TimeInterval?
    var snapshotQueuedCount = 0
    var snapshotIssuedCount = 0
    var snapshotSuccessCount = 0
    var snapshotFailureCount = 0
    var snapshotTimeoutCount = 0
    var firstBatteryWakeLeaseStartedAt: TimeInterval?
    var firstBatteryTrustedStillAt: TimeInterval?
    var batteryWakeLeaseStartedCount = 0
    var batteryTrustedStillCount = 0
    var batteryWakeFailureCount = 0
    var batteryWakeTimeoutCount = 0

    mutating func recordTrustedImage(at elapsed: TimeInterval) {
        if firstTrustedImageAt == nil {
            firstTrustedImageAt = elapsed
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

    mutating func recordSnapshotSuccess(at elapsed: TimeInterval) {
        snapshotSuccessCount += 1
        lastSnapshotSuccessAt = elapsed
        if firstSnapshotSuccessAt == nil {
            firstSnapshotSuccessAt = elapsed
        }
    }

    mutating func recordSnapshotFailure() {
        snapshotFailureCount += 1
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
    }

    mutating func recordBatteryWakeFailure() {
        batteryWakeFailureCount += 1
    }

    mutating func recordBatteryWakeTimeout() {
        batteryWakeTimeoutCount += 1
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
    let snapshotInFlightAge: TimeInterval?
    let nextEligibleSnapshotIn: TimeInterval?
    let lastSnapshotRequestAge: TimeInterval?
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
    let maxConcurrentSnapshotRequests: Int
    let snapshotRequestTimeout: TimeInterval
    let untrustedSnapshotRefreshInterval: TimeInterval
    let trustedSnapshotRefreshInterval: TimeInterval
    let batteryCaptureWarmup: TimeInterval
    let batteryWakeLeaseDuration: TimeInterval
    let batteryWakeLiveStartTimeout: TimeInterval
    let restrictedStartupSnapshotPrimingSeconds: Int
    let liveCapacityExpansionBlockedUntil: Date?
    let liveCapacityIncludesUnconfirmedMemory: Bool
    let restrictedStartupSnapshotPrimingStartedAt: Date?
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
        lines.append("maxConcurrentSnapshotRequests=\(maxConcurrentSnapshotRequests)")
        lines.append("snapshotRequestTimeout=\(formatSeconds(snapshotRequestTimeout))")
        lines.append("untrustedSnapshotRefreshInterval=\(formatSeconds(untrustedSnapshotRefreshInterval))")
        lines.append("trustedSnapshotRefreshInterval=\(formatSeconds(trustedSnapshotRefreshInterval))")
        lines.append("batteryCaptureWarmup=\(formatSeconds(batteryCaptureWarmup))")
        lines.append("batteryWakeLeaseDuration=\(formatSeconds(batteryWakeLeaseDuration))")
        lines.append("batteryWakeLiveStartTimeout=\(formatSeconds(batteryWakeLiveStartTimeout))")
        lines.append("restrictedStartupSnapshotPriming=\(restrictedStartupSnapshotPrimingSeconds)s")
        lines.append("liveCapacityExpansionBlockedFor=\(dateDelta(liveCapacityExpansionBlockedUntil, from: generatedAt))")
        lines.append("liveCapacityIncludesUnconfirmedMemory=\(liveCapacityIncludesUnconfirmedMemory)")
        lines.append("primingAge=\(ageLine(restrictedStartupSnapshotPrimingStartedAt, at: generatedAt))")
        lines.append("")
        lines.append("Startup Milestones")
        lines.append("enteredConstrainedModeAt=\(optionalSeconds(startupMilestones.enteredConstrainedModeAt))")
        lines.append("enteredConstrainedModeLiveCapacity=\(startupMilestones.enteredConstrainedModeLiveCapacity.map(String.init) ?? "nil")")
        lines.append("firstConstrainedSignalAt=\(optionalSeconds(startupMilestones.firstConstrainedSignalAt))")
        lines.append("firstConstrainedSignalFeedID=\(startupMilestones.firstConstrainedSignalFeedID ?? "nil")")
        lines.append("primingStartedAt=\(optionalSeconds(startupMilestones.primingStartedAt))")
        lines.append("primingEndedAt=\(optionalSeconds(startupMilestones.primingEndedAt))")
        lines.append("primingEndedReason=\(startupMilestones.primingEndedReason ?? "nil")")
        lines.append("allVisibleFeedsTrustedAt=\(optionalSeconds(startupMilestones.allVisibleFeedsTrustedAt))")
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
            lines.append(contentsOf: events.map { "+\(formatSeconds($0.elapsed)) \($0.message)" })
        }
        return lines.joined(separator: "\n")
    }

    private func feedMilestoneLine(_ milestones: CameraStartupTelemetryFeedMilestones) -> String {
        [
            milestones.feedID,
            "firstTrustedImageAt=\(optionalSeconds(milestones.firstTrustedImageAt))",
            "firstSnapshotQueuedAt=\(optionalSeconds(milestones.firstSnapshotQueuedAt))",
            "firstSnapshotIssuedAt=\(optionalSeconds(milestones.firstSnapshotIssuedAt))",
            "firstSnapshotSuccessAt=\(optionalSeconds(milestones.firstSnapshotSuccessAt))",
            "lastSnapshotSuccessAt=\(optionalSeconds(milestones.lastSnapshotSuccessAt))",
            "snapshotQueuedCount=\(milestones.snapshotQueuedCount)",
            "snapshotIssuedCount=\(milestones.snapshotIssuedCount)",
            "snapshotSuccessCount=\(milestones.snapshotSuccessCount)",
            "snapshotFailureCount=\(milestones.snapshotFailureCount)",
            "snapshotTimeoutCount=\(milestones.snapshotTimeoutCount)",
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
            "snapshotInFlightAge=\(optionalSeconds(feed.snapshotInFlightAge))",
            "nextEligibleSnapshotIn=\(optionalSeconds(feed.nextEligibleSnapshotIn))",
            "lastSnapshotRequestAge=\(optionalSeconds(feed.lastSnapshotRequestAge))",
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
        case .failure:
            return "\(baseMessage) imageUpdated=false"
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
        warmup: TimeInterval,
        now: Date
    ) -> Bool {
        guard isBatteryCamera, isStreaming, let liveStartedAt else { return false }

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
        previousCapacity: Int,
        currentLiveCount: Int,
        visibleFeedCount: Int
    ) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        let observedCapacity = boundedCapacity(
            observedLiveCount: max(previousCapacity, currentLiveCount),
            visibleFeedCount: visibleFeedCount
        )
        return min(max(1, observedCapacity), visibleFeedCount)
    }

    private static func boundedCapacity(observedLiveCount: Int, visibleFeedCount: Int) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        return min(max(1, observedLiveCount), visibleFeedCount)
    }
}
