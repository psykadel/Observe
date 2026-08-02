import CoreLocation
import Foundation
import HomeKit
import NetworkExtension
#if targetEnvironment(macCatalyst)
import Darwin
import ObjectiveC.runtime
#endif

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
    @Published private(set) var lockOptions: [HomeSecurityOption] = []
    @Published private(set) var temperatureSensorOptions: [HomeSecurityOption] = []
    @Published private(set) var lockIndicatorState: LockIndicatorState = .loading
    @Published private(set) var temperatureIndicatorState: TemperatureIndicatorState = .loading
    @Published private(set) var isSuccessIndicatorHealthy = false
    @Published private(set) var restrictedStartupOverlayPresentation: RestrictedStartupOverlayPresentation?
    @Published private(set) var currentWiFiSSID: String?
    @Published private(set) var connectionModeResolution = CameraConnectionModeResolution(
        mode: .restricted,
        reason: .homeNetworkNotConfigured
    )

    let preferences: ObservePreferences

    private let homeManager = HMHomeManager()
    private let locationManager = CLLocationManager()
    private let networkPathClassifier: any CameraNetworkPathClassifying
    private weak var selectedHome: HMHome?
    private var snapshotSchedulerTask: Task<Void, Never>?
    private var ssidRefreshTask: Task<Void, Never>?
    private var feedScheduleStates: [String: FeedScheduleState] = [:]
    private var currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
    private var liveAdmissionController = LiveAdmissionController(
        mode: .adaptive(maxPendingStarts: 1),
        sustainableCapacity: 0
    )
    private var lastLiveAdmissionDecision: LiveAdmissionDecision?
    private var liveCapacityIncludesUnconfirmedMemory = false
    private var isDiscoveringRestrictedLiveCapacity = false
    private var startupCoverageActive = true
    private var lastLivePlanTelemetrySignature: String?
    private var sessionNetworkClass: CameraNetworkClass = .unknown
    private var networkRevision: UInt64 = 0
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
    private var lockCharacteristicsByID: [String: HMCharacteristic] = [:]
    private var temperatureCharacteristicsByID: [String: HMCharacteristic] = [:]
    private var lockValuesByID: [String: Int] = [:]
    private var temperatureValuesByID: [String: Double] = [:]
    private var pendingLockReadIDs: Set<String>?
    private var pendingTemperatureReadIDs: Set<String>?
    private var lockLoadGeneration: UInt64 = 0
    private var temperatureLoadGeneration: UInt64 = 0

    private let maxTelemetryEvents = 400

    private var batteryCaptureWarmup: TimeInterval {
        preferences.batteryCaptureWarmupThreshold
    }

    init(
        preferences: ObservePreferences,
        networkPathClassifier: any CameraNetworkPathClassifying = CameraNetworkPathMonitor.shared
    ) {
        self.preferences = preferences
        self.networkPathClassifier = networkPathClassifier
        self.networkRevision = networkPathClassifier.revision
        self.authorizationStatus = homeManager.authorizationStatus
        super.init()
        homeManager.delegate = self
        locationManager.delegate = self
        refreshCurrentWiFiSSID()
        rebuildHomesAndFeeds()
    }

    var selectedHomeID: String? { preferences.selectedHomeID }

    var priorityOrderedFeeds: [CameraFeedCoordinator] {
        let normalized = preferences.normalizedPriority(availableIDs: feeds.map(\.id))
        let feedLookup = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        return normalized.compactMap { feedLookup[$0] }
    }

    var livePriorityOrderedFeeds: [CameraFeedCoordinator] {
        let cameraOrderedFeeds = priorityOrderedFeeds
        let normalized = preferences.normalizedLivePriority(availableIDs: cameraOrderedFeeds.map(\.id))
        let feedLookup = Dictionary(uniqueKeysWithValues: cameraOrderedFeeds.map { ($0.id, $0) })
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
            currentWiFiSSID = nil
            updateConnectionMode(at: Date(), refreshPresentation: false)
            rebuildHomesAndFeeds()
        } else {
            deactivateSession()
        }
    }

    func selectHome(id: String) {
        preferences.selectedHomeID = id
        rebuildHomesAndFeeds()
    }

    func setHomeNetworkSSID(_ ssid: String) {
        preferences.setHomeNetworkSSID(ssid)
        updateConnectionMode(at: Date(), refreshPresentation: true)
    }

    func requestHomeNetworkAccess() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            refreshCurrentWiFiSSID()
        case .denied, .restricted:
            currentWiFiSSID = nil
            updateConnectionMode(at: Date(), refreshPresentation: true)
        @unknown default:
            currentWiFiSSID = nil
            updateConnectionMode(at: Date(), refreshPresentation: true)
        }
    }

    func setLockStatusEnabled(_ enabled: Bool) {
        preferences.setLockStatusEnabled(enabled)
        resetLockStatus()
        serviceHomeSecurity()
        refreshSuccessIndicatorHealth()
    }

    func setHomeTemperatureEnabled(_ enabled: Bool) {
        preferences.setHomeTemperatureEnabled(enabled)
        resetTemperatureStatus()
        serviceHomeSecurity()
        refreshSuccessIndicatorHealth()
    }

    func setLockSelected(_ selected: Bool, for id: String) {
        preferences.setLockSelected(selected, for: id)
        resetLockStatus()
        serviceHomeSecurity()
        refreshSuccessIndicatorHealth()
    }

    func setTemperatureSensorSelected(_ selected: Bool, for id: String) {
        preferences.setTemperatureSensorSelected(selected, for: id)
        resetTemperatureStatus()
        serviceHomeSecurity()
        refreshSuccessIndicatorHealth()
    }

    func setHomeTemperatureLowFahrenheit(_ value: Int) {
        preferences.setHomeTemperatureLowFahrenheit(value)
        refreshTemperatureIndicator()
    }

    func setHomeTemperatureHighFahrenheit(_ value: Int) {
        preferences.setHomeTemperatureHighFahrenheit(value)
        refreshTemperatureIndicator()
    }

    func movePriority(from source: IndexSet, to destination: Int) {
        preferences.movePriority(from: source, to: destination, availableIDs: feeds.map(\.id))
        objectWillChange.send()
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    func moveLivePriority(from source: IndexSet, to destination: Int) {
        preferences.moveLivePriority(
            from: source,
            to: destination,
            availableIDs: priorityOrderedFeeds.map(\.id)
        )
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
        let snapshotStates = feedScheduleStates.values.map(\.snapshotWorkState)
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
            liveAdmissionPlannerCapacity: liveAdmissionController.lastPlannerCapacity,
            liveAdmissionEffectiveCapacity: liveAdmissionController.lastEffectiveCapacity,
            liveAdmissionCapacityLimitReason: liveAdmissionController.lastCapacityLimitReason,
            liveAdmissionTargetIDs: lastLiveAdmissionDecision?.targetIDs ?? [],
            liveAdmissionReservedIDs: lastLiveAdmissionDecision?.reservedTransportIDs ?? [],
            liveAdmissionQueuedIDs: lastLiveAdmissionDecision?.queuedStartIDs ?? [],
            visibleFeedCount: wallFeeds.count,
            trustedSnapshotRefreshInterval: CameraSchedulingDefaults.minimumSnapshotRefreshInterval,
            batteryCaptureWarmup: batteryCaptureWarmup,
            batteryWakeTriggerThreshold: preferences.batteryWakeTriggerThreshold,
            startupCoverageActive: startupCoverageActive,
            sessionNetworkClass: sessionNetworkClass.rawValue,
            currentNetworkClass: networkPathClassifier.currentClass.rawValue,
            connectionMode: connectionModeResolution.mode.rawValue,
            connectionModeReason: connectionModeResolution.reason.rawValue,
            restrictedLiveCapacityDiscoveryActive: isDiscoveringRestrictedLiveCapacity,
            outstandingSnapshotRequests: snapshotStates.filter(\.isOutstanding).count,
            startupMetadataMode: startupMetadataMode.rawValue,
            startupMetadataGateState: startupMetadataGateState,
            activeMetadataOperations: activeStartupMetadataOperation == nil ? 0 : 1,
            queuedMetadataOperations: startupMetadataQueue.count,
            activeMetadataOperation: activeStartupMetadataOperation?.descriptor.telemetryLabel,
            liveCapacityIncludesUnconfirmedMemory: liveCapacityIncludesUnconfirmedMemory,
            startupMilestones: telemetryStartupMilestones,
            feeds: telemetryFeeds(at: now),
            events: telemetryEvents
        ).text
    }

    private func rebuildHomesAndFeeds() {
        sessionGeneration &+= 1
        restrictedStartupOverlayPresentation = nil
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
            connectionMode: CameraConnectionModePolicy.resolve(
                networkClass: networkPathClassifier.currentClass,
                currentSSID: currentWiFiSSID,
                configuredHomeSSID: preferences.homeNetworkSSID
            ).mode
        )
        var discoveredFeeds: [CameraFeedCoordinator] = []
        var discoveredLocks: [HomeSecurityOption] = []
        var discoveredTemperatureSensors: [HomeSecurityOption] = []
        lockCharacteristicsByID = [:]
        temperatureCharacteristicsByID = [:]
        for accessory in home.accessories {
            accessory.delegate = self

            for service in accessory.services {
                if service.serviceType == HMServiceTypeLockMechanism,
                   let characteristic = service.characteristics.first(where: {
                       $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState
                   }) {
                    let id = service.uniqueIdentifier.uuidString
                    lockCharacteristicsByID[id] = characteristic
                    discoveredLocks.append(
                        HomeSecurityOption(id: id, name: accessory.name, roomName: accessory.room?.name)
                    )
                }

                let currentTemperature = service.characteristics.first(where: {
                    $0.characteristicType == HMCharacteristicTypeCurrentTemperature
                })
                if HomeTemperatureDiscoveryPolicy.includes(
                    hasCurrentTemperature: currentTemperature != nil
                ), let characteristic = currentTemperature {
                    let id = service.uniqueIdentifier.uuidString
                    temperatureCharacteristicsByID[id] = characteristic
                    discoveredTemperatureSensors.append(
                        HomeSecurityOption(
                            id: id,
                            name: HomeTemperatureDiscoveryPolicy.optionName(
                                serviceName: service.name,
                                accessoryName: accessory.name
                            ),
                            roomName: accessory.room?.name
                        )
                    )
                }
            }

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
        lockOptions = discoveredLocks.sorted(by: homeSecurityOptionSort)
        temperatureSensorOptions = discoveredTemperatureSensors.sorted(by: homeSecurityOptionSort)
        resetHomeSecurityStatus()

        let priorityIDs = preferences.normalizedPriority(availableIDs: discoveredFeeds.map(\.id))
        let feedLookup = Dictionary(uniqueKeysWithValues: discoveredFeeds.map { ($0.id, $0) })
        feeds = priorityIDs.compactMap { feedLookup[$0] }
        _ = preferences.normalizedLivePriority(availableIDs: priorityIDs)

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
        ssidRefreshTask?.cancel()
        focusedFeedID = nil
        liveCapacity = 0
        liveCapacityIncludesUnconfirmedMemory = false
        isDiscoveringRestrictedLiveCapacity = false
        startupCoverageActive = true
        lastLivePlanTelemetrySignature = nil
        resetStartupMetadataWork()
        currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
        liveAdmissionController = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: 1),
            sustainableCapacity: 0
        )
        lastLiveAdmissionDecision = nil
        restrictedStartupOverlayPresentation = nil
        feeds.forEach { $0.resetSessionState() }
        resetHomeSecurityStatus()
    }

    private func clearMissingHomeState() {
        feeds = []
        lockOptions = []
        temperatureSensorOptions = []
        lockCharacteristicsByID = [:]
        temperatureCharacteristicsByID = [:]
        resetHomeSecurityStatus()
        feedScheduleStates = [:]
        currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
        liveAdmissionController = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: 1),
            sustainableCapacity: 0
        )
        lastLiveAdmissionDecision = nil
        liveCapacity = 0
        liveCapacityIncludesUnconfirmedMemory = false
        isDiscoveringRestrictedLiveCapacity = false
        startupCoverageActive = true
        restrictedStartupOverlayPresentation = nil
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
        liveCapacityIncludesUnconfirmedMemory = false
        isDiscoveringRestrictedLiveCapacity = false
        startupCoverageActive = true
        lastLivePlanTelemetrySignature = nil
        resetHomeSecurityStatus()
    }

    private func startSession() {
        snapshotSchedulerTask?.cancel()
        ssidRefreshTask?.cancel()

        guard isAppActive else { return }
        guard !feeds.isEmpty else {
            serviceHomeSecurity()
            return
        }

        telemetrySessionStartedAt = Date()
        telemetryEvents = []
        nextTelemetrySequence = 1
        telemetryStartupMilestones = CameraStartupTelemetryMilestones()
        nextSnapshotRequestID = 1
        startupCoverageActive = true
        lastLivePlanTelemetrySignature = nil
        let networkClass = networkPathClassifier.currentClass
        networkRevision = networkPathClassifier.revision
        sessionNetworkClass = networkClass
        connectionModeResolution = CameraConnectionModePolicy.resolve(
            networkClass: networkClass,
            currentSSID: currentWiFiSSID,
            configuredHomeSSID: preferences.homeNetworkSSID
        )
        configureLiveCapacityForCurrentMode()
        startupMetadataMode = StartupMetadataWorkMode.resolve(
            connectionMode: connectionModeResolution.mode
        )
        activeStartupMetadataOperation = nil
        initialMediaAdmissionCompleted = startupMetadataMode == .immediateParallel
        startupMetadataQueue = startupMetadataMode == .mediaPrioritySerial
            ? StartupMetadataAdmissionPolicy.ordered(feeds.flatMap { $0.startupMetadataOperations() })
            : []
        recordTelemetry(
            "session start feeds=\(feeds.count) visible=\(wallFeeds.count) liveCapacity=\(liveCapacity) network=\(networkClass.rawValue) connectionMode=\(connectionModeResolution.mode.rawValue) reason=\(connectionModeResolution.reason.rawValue)"
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
        refreshCurrentWiFiSSID()

        snapshotSchedulerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    self.refreshPresentation(focusedFeedID: self.focusedFeedID)
                }
            }
        }
    }

    private func configureLiveCapacityForCurrentMode() {
        let visibleIDs = wallFeeds.map(\.id)
        if connectionModeResolution.mode == .homeNetwork {
            liveCapacity = visibleIDs.count
            isDiscoveringRestrictedLiveCapacity = false
        } else if let remembered = preferences.rememberedRestrictedLiveCapacity(
            homeID: selectedHome?.uniqueIdentifier.uuidString,
            visibleCameraIDs: visibleIDs
        ) {
            liveCapacity = remembered
            isDiscoveringRestrictedLiveCapacity = false
        } else {
            liveCapacity = 0
            isDiscoveringRestrictedLiveCapacity = !visibleIDs.isEmpty
        }

        liveAdmissionController = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: connectionModeResolution.mode == .homeNetwork ? Int.max : 1),
            sustainableCapacity: liveCapacity
        )
    }

    private func acceptsCallback(generation: UInt64) -> Bool {
        CameraSessionGeneration.accepts(
            callbackGeneration: generation,
            activeGeneration: sessionGeneration
        )
    }

    private func refreshCurrentWiFiSSID() {
        ssidRefreshTask?.cancel()
        let lookupSources = CurrentWiFiSSIDLookupPolicy.sources(
            isMacCatalyst: Self.isMacCatalyst,
            networkClass: networkPathClassifier.currentClass
        )
        guard !lookupSources.isEmpty else {
            currentWiFiSSID = nil
            updateConnectionMode(at: Date(), refreshPresentation: true)
            return
        }

        let requestedRevision = networkPathClassifier.revision
        ssidRefreshTask = Task { @MainActor [weak self] in
            let ssid = await Self.fetchCurrentWiFiSSID(using: lookupSources)
            guard let self,
                  !Task.isCancelled,
                  self.networkPathClassifier.revision == requestedRevision else { return }

            self.currentWiFiSSID = ssid
            self.updateConnectionMode(at: Date(), refreshPresentation: true)
        }
    }

    private static var isMacCatalyst: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        false
#endif
    }

    private static func fetchCurrentWiFiSSID(
        using sources: [CurrentWiFiSSIDLookupSource]
    ) async -> String? {
        for source in sources {
            switch source {
            case .coreWLAN:
#if targetEnvironment(macCatalyst)
                if let ssid = fetchCurrentWiFiSSIDUsingCoreWLAN() {
                    return ssid
                }
#endif
            case .networkExtension:
                if let ssid = await fetchCurrentWiFiSSIDUsingNetworkExtension() {
                    return ssid
                }
            }
        }
        return nil
    }

#if targetEnvironment(macCatalyst)
    private static func fetchCurrentWiFiSSIDUsingCoreWLAN() -> String? {
        guard dlopen(
            "/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN",
            RTLD_LAZY | RTLD_LOCAL
        ) != nil,
        let clientClass = NSClassFromString("CWWiFiClient"),
        let client = invokeObjectReturningSelector("sharedWiFiClient", on: clientClass),
        let interface = invokeObjectReturningSelector("interface", on: client),
        let ssid = invokeObjectReturningSelector("ssid", on: interface) as? String else {
            return nil
        }
        return ssid
    }

    private static func invokeObjectReturningSelector(
        _ selectorName: String,
        on receiver: AnyObject
    ) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard let receiverClass = object_getClass(receiver),
              let method = class_getInstanceMethod(receiverClass, selector) else {
            return nil
        }

        typealias SelectorFunction = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let function = unsafeBitCast(method_getImplementation(method), to: SelectorFunction.self)
        return function(receiver, selector)?.takeUnretainedValue()
    }
#endif

    private static func fetchCurrentWiFiSSIDUsingNetworkExtension() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    private func handleNetworkPathChangeIfNeeded(at date: Date) {
        let revision = networkPathClassifier.revision
        guard revision != networkRevision else { return }

        networkRevision = revision
        currentWiFiSSID = nil
        updateConnectionMode(at: date, refreshPresentation: false)
        refreshCurrentWiFiSSID()
    }

    private func updateConnectionMode(at date: Date, refreshPresentation shouldRefresh: Bool) {
        let previous = connectionModeResolution
        let resolved = CameraConnectionModePolicy.resolve(
            networkClass: networkPathClassifier.currentClass,
            currentSSID: currentWiFiSSID,
            configuredHomeSSID: preferences.homeNetworkSSID
        )
        sessionNetworkClass = networkPathClassifier.currentClass
        guard resolved != previous else { return }

        connectionModeResolution = resolved
        if resolved.mode != previous.mode {
            applyConnectionModeTransition(from: previous.mode, to: resolved.mode)
        }
        if !feeds.isEmpty {
            recordTelemetry(
                "connection mode resolved mode=\(resolved.mode.rawValue) reason=\(resolved.reason.rawValue)",
                at: date
            )
        }
        if shouldRefresh, isAppActive {
            refreshPresentation(focusedFeedID: focusedFeedID)
        }
    }

    private func applyConnectionModeTransition(
        from previousMode: CameraConnectionMode,
        to mode: CameraConnectionMode
    ) {
        sessionMode = .optimistic
        liveCapacityIncludesUnconfirmedMemory = false
        isDiscoveringRestrictedLiveCapacity = false
        startupCoverageActive = true
        configureLiveCapacityForCurrentMode()
        lastLiveAdmissionDecision = nil

        if mode == .homeNetwork {
            startupMetadataMode = .immediateParallel
            startupMetadataQueue = []
            activeStartupMetadataOperation = nil
            initialMediaAdmissionCompleted = true
            for feed in feeds {
                feed.readHomeKitCameraActiveState()
                feed.readBatteryPercentage()
            }
            for (feedID, var state) in feedScheduleStates {
                if case .queued = state.snapshotWorkState {
                    state.snapshotWorkState = .idle
                    feedScheduleStates[feedID] = state
                }
            }
        } else if previousMode == .homeNetwork {
            startupMetadataMode = .mediaPrioritySerial
            startupMetadataQueue = StartupMetadataAdmissionPolicy.ordered(
                feeds.flatMap { $0.startupMetadataOperations() }
            )
            activeStartupMetadataOperation = nil
            initialMediaAdmissionCompleted = false
            for (feedID, var state) in feedScheduleStates {
                applyStartupEvent(.reset, feedID: feedID, state: &state)
                feedScheduleStates[feedID] = state
            }
        }
    }

    private func refreshPresentation(focusedFeedID: String?) {
        guard isAppActive else { return }

        handleNetworkPathChangeIfNeeded(at: Date())
        configureFeedsForPresentation()
        let now = Date()
        reconcileFeedScheduleStates(at: now)

        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        updateTrustedImageMilestones(from: planningSnapshots, at: now)
        updateStartupCoverage(from: planningSnapshots, at: now)

        let liveBudget = resolveLiveBudget(from: planningSnapshots)
        let startupLivePolicy = resolveStartupLivePolicy(from: planningSnapshots)
        currentRecoveryPlan = CameraRecoveryPlanner().makePlan(
            feeds: planningSnapshots,
            liveCapacity: liveBudget,
            startupLivePolicy: startupLivePolicy,
            now: now
        )

        cancelBatteryWakeLeasesSupersededByFocus(at: now)
        let (admission, desiredLiveIDs) = reconcileLiveAdmission(
            focusedFeedID: focusedFeedID,
            liveBudget: liveBudget,
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
        serviceHomeSecurity()
        updateRestrictedStartupOverlay(at: now)
        refreshSuccessIndicatorHealth(at: now)
    }

    private func updateRestrictedStartupOverlay(at now: Date) {
        let snapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        let isRestrictedStartup = connectionModeResolution.mode == .restricted
            && !snapshots.contains { $0.hasTrustedImage(at: now) }
        let cameras = wallFeeds.map { feed in
            return RestrictedStartupCameraActivity(
                hasCurrentPicture: hasTrustedImage(feedID: feed.id, at: now)
            )
        }
        let presentation = RestrictedStartupOverlayPolicy.presentation(
            isRestrictedStartup: isRestrictedStartup,
            hasHome: selectedHome != nil,
            cameras: cameras
        )

        if restrictedStartupOverlayPresentation != presentation {
            restrictedStartupOverlayPresentation = presentation
        }
    }

    private var startupMetadataGateState: String {
        StartupMetadataGateStatePolicy.resolve(
            mode: startupMetadataMode,
            initialMediaAdmissionCompleted: initialMediaAdmissionCompleted,
            hasQueuedOperations: !startupMetadataQueue.isEmpty,
            activeOperationKind: activeStartupMetadataOperation?.descriptor.kind,
            completedOperationCount: telemetryStartupMilestones.metadata.completedCount,
            allVisibleFeedsTrusted: allVisibleFeedsTrusted(at: Date()),
            criticalMediaWorkActive: criticalMediaWorkActive
        )
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
        guard limit > 0, activeStartupMetadataOperation == nil else { return }

        let now = Date()
        let allVisibleFeedsTrusted = allVisibleFeedsTrusted(at: now)
        let hasCriticalMediaWork = criticalMediaWorkActive
        guard let operationIndex = startupMetadataQueue.firstIndex(where: { operation in
            StartupMetadataAdmissionPolicy.shouldIssue(
                kind: operation.kind,
                mode: startupMetadataMode,
                initialMediaAdmissionCompleted: initialMediaAdmissionCompleted,
                allVisibleFeedsTrusted: allVisibleFeedsTrusted,
                criticalMediaWorkActive: hasCriticalMediaWork
            )
        }) else { return }

        let operation = startupMetadataQueue.remove(at: operationIndex)
        let issuedAt = now
        activeStartupMetadataOperation = ActiveStartupMetadataOperation(
            descriptor: operation,
            issuedAt: issuedAt
        )
        let isFirstRead = !operation.kind.isNotificationRegistration
            && telemetryStartupMilestones.metadata.firstReadIssuedAt == nil
        telemetryStartupMilestones.metadata.recordIssued(
            kind: operation.kind,
            activeCount: 1,
            at: elapsedSinceSession(issuedAt)
        )
        if isFirstRead {
            recordTelemetry(
                "metadata explicit reads opened allVisibleTrusted=true criticalMediaWorkActive=false",
                at: issuedAt
            )
        }
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

    private func resolveLiveBudget(from planningSnapshots: [FeedPlanningSnapshot]) -> Int {
        if connectionModeResolution.mode == .homeNetwork {
            return planningSnapshots.count
        }
        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        if liveCapacityIncludesUnconfirmedMemory, currentLiveCount >= liveCapacity {
            liveCapacityIncludesUnconfirmedMemory = false
        }
        liveCapacity = RestrictedLiveCapacity.recordSuccessfulStreams(
            previousCapacity: liveCapacity,
            currentLiveCount: currentLiveCount,
            visibleFeedCount: planningSnapshots.count
        )
        if isDiscoveringRestrictedLiveCapacity,
           !planningSnapshots.isEmpty,
           currentLiveCount == planningSnapshots.count {
            isDiscoveringRestrictedLiveCapacity = false
            recordRememberedRestrictedLiveCapacity(currentLiveCount)
        }
        return RestrictedLiveCapacity.planningBudget(
            knownCapacity: liveCapacity,
            currentLiveCount: currentLiveCount,
            visibleFeedCount: planningSnapshots.count,
            isDiscovering: isDiscoveringRestrictedLiveCapacity
        )
    }

    private func resolveStartupLivePolicy(
        from planningSnapshots: [FeedPlanningSnapshot]
    ) -> StartupLivePolicy {
        if connectionModeResolution.mode == .homeNetwork {
            return .homeNetwork(liveIDs: Set(planningSnapshots.map(\.id)))
        } else {
            return .normal
        }
    }

    private func reconcileLiveAdmission(
        focusedFeedID: String?,
        liveBudget: Int,
        now: Date
    ) -> (LiveAdmissionDecision, Set<String>) {
        let desiredLiveIDs = Set(currentRecoveryPlan.decisionsByID.compactMap { id, decision in
            decision.presentationMode == .live ? id : nil
        })
        let admissionMode: LiveAdmissionMode
        if connectionModeResolution.mode == .homeNetwork {
            admissionMode = .adaptive(maxPendingStarts: Int.max)
        } else if sessionMode == .constrained {
            admissionMode = .constrained
        } else {
            admissionMode = .adaptive(
                maxPendingStarts: isDiscoveringRestrictedLiveCapacity ? 1 : max(1, liveBudget)
            )
        }
        liveAdmissionController.update(mode: admissionMode, sustainableCapacity: liveCapacity)

        let visibleFeeds = wallFeeds
        let usesLivePriority = LiveAdmissionOrderingPolicy.usesLiveOrder(
            connectionMode: connectionModeResolution.mode
        )
        let admissionOrderedFeeds = usesLivePriority
            ? livePriorityOrderedFeeds.filter { isVisibleOnWall($0) }
            : visibleFeeds
        let priorityByID = Dictionary(
            uniqueKeysWithValues: admissionOrderedFeeds.enumerated().map { ($0.element.id, $0.offset) }
        )
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
        let admission = liveAdmissionController.reconcile(
            intents: liveIntents,
            transports: transports,
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
        for feed in feeds where isVisibleOnWall(feed) {
            guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { continue }
            if decision.snapshotPriority != .none, !feed.isStreaming {
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
            "capacityLimit=\(liveAdmissionController.lastCapacityLimitReason)"
        ].joined(separator: " ")
        guard signature != lastLivePlanTelemetrySignature else { return }
        lastLivePlanTelemetrySignature = signature
        recordTelemetry("live plan \(signature)")
    }

    private func planningSnapshots(at now: Date, focusedFeedID: String?) -> [FeedPlanningSnapshot] {
        let livePriorityByID = Dictionary(
            uniqueKeysWithValues: livePriorityOrderedFeeds
                .filter { isVisibleOnWall($0) }
                .enumerated()
                .map { ($0.element.id, $0.offset) }
        )
        return wallFeeds.enumerated().map { index, feed in
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
                livePriorityIndex: livePriorityByID[feed.id] ?? Int.max,
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

    private func reconcileFeedScheduleStates(at now: Date) {
        reconcileHiddenBatteryCameraWork()

        for feed in feeds {
            guard var state = feedScheduleStates[feed.id] else { continue }

            let isBatteryCamera = preferences.isBatteryWakeCamera(id: feed.id)
            let shouldClearBatteryCapture = !isVisibleOnWall(feed)
                || !isBatteryCamera
                || hasTrustedBatteryStill(feed, at: now)
            guard shouldClearBatteryCapture else { continue }

            state.batteryWakeLeaseStartedAt = nil
            state.batteryWakeRetryAfter = nil
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
            feedScheduleStates[feedID] = state
            return
        }

        guard decision.recoveryPhase == .batteryCapture else {
            state.batteryWakeLeaseStartedAt = nil
            feedScheduleStates[feedID] = state
            return
        }
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
            warmup: batteryCaptureWarmup,
            now: now
        ) else {
            return
        }

        feed.markBatteryStillCaptured(at: now)
        state.batteryWakeLeaseStartedAt = nil
        state.batteryWakeRetryAfter = nil
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
        state.batteryWakeRetryAfter = date.addingTimeInterval(CameraSchedulingDefaults.failureRetryDelay)
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
        let eligibleAt: Date
        if startupCoverageActive,
           state.startupState.snapshotAttempted,
           state.startupState.snapshotFailed {
            guard let recoveryEligibleAt = StartupSnapshotRecoveryPolicy.retryEligibleDate(
                startupCoverageActive: true,
                startupState: state.startupState,
                snapshotFailedAt: state.lastSnapshotFailureAt
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
            applyStartupEvent(.reset, feedID: feed.id, state: &state)
            feedScheduleStates[feed.id] = state
        }

        liveCapacity = min(liveCapacity, wallFeeds.count)
        if wallFeeds.isEmpty {
            liveCapacityIncludesUnconfirmedMemory = false
            startupCoverageActive = true
        }
    }

    private func serviceSnapshotQueue() {
        guard isAppActive else { return }
        let now = Date()
        let feedLookup = Dictionary(uniqueKeysWithValues: wallFeeds.map { ($0.id, $0) })
        let snapshotFeeds = currentRecoveryPlan.orderedSnapshotIDs.compactMap { feedLookup[$0] }
        let dueFeeds = snapshotFeeds
            .filter { feed in
                guard let state = feedScheduleStates[feed.id] else { return false }
                guard case .queued(_, let eligibleAt) = state.snapshotWorkState else { return false }
                return eligibleAt <= now
            }

        for feed in dueFeeds {
            if issueSnapshotRequest(for: feed, at: now) {
                let snapshotStates = feedScheduleStates.values.map(\.snapshotWorkState)
                telemetryStartupMilestones.recordSnapshotConcurrency(
                    outstanding: snapshotStates.filter(\.isOutstanding).count
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
                    issuedAt: date
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
                snapshotFailedAt: date
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

    private func allVisibleFeedsTrusted(at date: Date) -> Bool {
        let snapshots = planningSnapshots(at: date, focusedFeedID: focusedFeedID)
        return !snapshots.isEmpty && snapshots.allSatisfy { $0.hasTrustedImage(at: date) }
    }

    private var criticalMediaWorkActive: Bool {
        feedScheduleStates.values.contains { $0.snapshotWorkState.isOutstanding }
            || wallFeeds.contains { feed in
                feed.liveTransportPhase == .starting || feed.liveTransportPhase == .stopping
            }
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
        connectionModeResolution.mode == .restricted
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
            snapshotFailedAt: date
        ) {
            state.snapshotWorkState = .queued(priority: priority, eligibleAt: eligibleAt)
        } else {
            state.snapshotWorkState = .idle
        }
        feedScheduleStates[feedID] = state
    }

    private func handleConstrainedSignal(from feedID: String) {
        let now = Date()
        guard connectionModeResolution.mode == .restricted else { return }
        if let feed = feeds.first(where: { $0.id == feedID }), !isVisibleOnWall(feed) {
            reconcileHiddenBatteryCameraWork()
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        telemetryStartupMilestones.recordConstrainedSignal(feedID: feedID, at: elapsedSinceSession(now))
        recordTelemetry("constrained signal \(feedID) mode=\(sessionMode) liveCapacity=\(liveCapacity)")
        isDiscoveringRestrictedLiveCapacity = false
        if keepBatteryWakeLeaseAliveAfterConstrainedSignal(for: feedID) {
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        let didConcludeBatteryWake = concludeBatteryWake(for: feedID, at: now)
        if !didConcludeBatteryWake {
            queueSnapshotRefresh(for: feedID)
        }

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

    private func keepBatteryWakeLeaseAliveAfterConstrainedSignal(for feedID: String) -> Bool {
        guard preferences.isBatteryWakeCamera(id: feedID),
              let feed = feeds.first(where: { $0.id == feedID }),
              let state = feedScheduleStates[feedID],
              let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt,
              feed.isStreaming,
              !didCaptureBatteryStill(for: feedID, since: batteryWakeLeaseStartedAt) else {
            return false
        }

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
        guard connectionModeResolution.mode == .restricted else { return }
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
            feedScheduleStates[feedID] = state
        }

        let visibleCount = wallFeeds.count
        liveCapacity = min(liveCapacity, visibleCount)
        if visibleCount == 0 {
            liveCapacityIncludesUnconfirmedMemory = false
            startupCoverageActive = true
            isDiscoveringRestrictedLiveCapacity = false
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
            liveAdmissionController.recordSuccess(feedID: feedID)
            let startedAtElapsed = elapsedSinceSession(startedAt)
            if connectionModeResolution.mode == .restricted,
               isDiscoveringRestrictedLiveCapacity {
                liveCapacity = RestrictedLiveCapacity.recordSuccessfulStreams(
                    previousCapacity: liveCapacity,
                    currentLiveCount: wallFeeds.filter(\.isStreaming).count,
                    visibleFeedCount: wallFeeds.count
                )
            }
            if var state = feedScheduleStates[feedID], state.startupState.resolution != .trusted {
                applyStartupEvent(.liveStarted, feedID: feedID, state: &state)
                feedScheduleStates[feedID] = state
            }
            telemetryStartupMilestones.recordLiveStarted(
                feedID: feedID,
                callbackLatency: callbackLatency,
                resolvesTrustedImage: true,
                at: startedAtElapsed
            )
            recordTelemetry(
                "live started \(feedID) callbackLatency=\(optionalSeconds(callbackLatency))",
                at: startedAt
            )
        case .stopRequested(let requestedAt):
            recordTelemetry(
                "live stop requested \(feedID)",
                at: requestedAt
            )
        case .stopped(let stoppedAt, let disposition, let callbackLatency):
            telemetryStartupMilestones.recordLiveStopped(
                feedID: feedID,
                callbackLatency: callbackLatency
            )
            let shouldFailCameraPath: Bool = switch disposition {
            case .retryableTransport, .cameraFailure, .ended: true
            case .requestedStop, .softContention, .hardCapacity, .infrastructureUnavailable: false
            }
            if shouldFailCameraPath,
               var state = feedScheduleStates[feedID],
               state.startupState.resolution != .trusted {
                let isBatteryCamera = preferences.isBatteryWakeCamera(id: feedID)
                if state.startupState.liveAttempted || isBatteryCamera {
                    applyStartupEvent(.liveFailed, feedID: feedID, state: &state)
                }
                feedScheduleStates[feedID] = state
            }
            recordTelemetry(
                "live stopped \(feedID) disposition=\(liveFailureDispositionLabel(disposition)) callbackLatency=\(optionalSeconds(callbackLatency)) error=\(transportErrorLabel(disposition.error))",
                at: stoppedAt
            )

            switch disposition {
            case .requestedStop:
                break
            case .softContention:
                if connectionModeResolution.mode == .homeNetwork {
                    liveAdmissionController.recordRetryableFailure(feedID: feedID, at: stoppedAt)
                    recordTelemetry(
                        "home network live retry queued \(feedID) disposition=softContention retryIn=\(optionalSeconds(liveAdmissionController.retryDelay(feedID: feedID, at: stoppedAt)))",
                        at: stoppedAt
                    )
                    break
                }
                liveCapacityIncludesUnconfirmedMemory = false
                liveAdmissionController.recordRetryableFailure(feedID: feedID, at: stoppedAt)
                recordTelemetry(
                    "live retry queued \(feedID) disposition=softContention retryIn=\(optionalSeconds(liveAdmissionController.retryDelay(feedID: feedID, at: stoppedAt)))",
                    at: stoppedAt
                )
            case .hardCapacity:
                if connectionModeResolution.mode == .homeNetwork {
                    liveAdmissionController.recordRetryableFailure(feedID: feedID, at: stoppedAt)
                    recordTelemetry(
                        "home network live retry queued \(feedID) disposition=hardCapacity retryIn=\(optionalSeconds(liveAdmissionController.retryDelay(feedID: feedID, at: stoppedAt)))",
                        at: stoppedAt
                    )
                    break
                }
                handleConstrainedSignal(from: feedID)
                return
            case .infrastructureUnavailable:
                liveAdmissionController.recordInfrastructureUnavailable(at: stoppedAt)
                recordTelemetry(
                    "live infrastructure retry queued retryIn=\(optionalSeconds(liveAdmissionController.infrastructureRetryDelay(at: stoppedAt)))",
                    at: stoppedAt
                )
            case .retryableTransport, .cameraFailure, .ended:
                liveAdmissionController.recordRetryableFailure(feedID: feedID, at: stoppedAt)
                recordTelemetry(
                    "live retry queued \(feedID) disposition=\(liveFailureDispositionLabel(disposition)) retryIn=\(optionalSeconds(liveAdmissionController.retryDelay(feedID: feedID, at: stoppedAt)))",
                    at: stoppedAt
                )
            }
        }

        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func liveFailureDispositionLabel(_ disposition: CameraLiveFailureDisposition) -> String {
        switch disposition {
        case .requestedStop: "requestedStop"
        case .softContention: "softContention"
        case .hardCapacity: "hardCapacity"
        case .infrastructureUnavailable: "infrastructureUnavailable"
        case .retryableTransport: "retryableTransport"
        case .cameraFailure: "cameraFailure"
        case .ended: "ended"
        }
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
                nextEligibleSnapshotIn: secondsUntil(nextEligibleSnapshotAt, from: now),
                lastSnapshotRequestAge: age(of: state?.lastSnapshotRequestIssuedAt, at: now),
                startupCoverageResolution: state.map { String(describing: $0.startupState.resolution) } ?? "unknown",
                startupSnapshotAttempted: state?.startupState.snapshotAttempted ?? false,
                startupSnapshotPath: state?.startupState.snapshotPath.label ?? "unknown",
                startupLivePath: state?.startupState.livePath.label ?? "unknown",
                batteryStillAge: age(of: feed.batteryStillDate, at: now),
                nextBatteryCaptureDueIn: BatteryCaptureTelemetryPolicy.nextCaptureDueIn(
                    isBatteryCamera: preferences.isBatteryWakeCamera(id: feed.id),
                    isStreaming: feed.isStreaming,
                    stillDate: feed.batteryStillDate,
                    triggerThreshold: preferences.batteryWakeTriggerThreshold,
                    now: now
                ),
                batteryCaptureSchedule: BatteryCaptureTelemetryPolicy.schedule(
                    isBatteryCamera: preferences.isBatteryWakeCamera(id: feed.id),
                    isStreaming: feed.isStreaming
                ),
                batteryWakeLeaseAge: age(of: state?.batteryWakeLeaseStartedAt, at: now),
                batteryWakeRetryIn: secondsUntil(state?.batteryWakeRetryAfter, from: now),
                liveStartedAge: age(of: feed.liveStartedAt, at: now),
                liveStartRequestedAge: age(of: feed.liveStartRequestedAt, at: now),
                liveStopRequestedAge: age(of: feed.liveStopRequestedAt, at: now),
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

    private func homeSecurityOptionSort(_ lhs: HomeSecurityOption, _ rhs: HomeSecurityOption) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private var selectedCurrentHomeLockIDs: Set<String> {
        Set(preferences.selectedLockIDs).intersection(lockCharacteristicsByID.keys)
    }

    private var selectedCurrentHomeTemperatureIDs: Set<String> {
        Set(preferences.selectedTemperatureSensorIDs).intersection(temperatureCharacteristicsByID.keys)
    }

    private func resetHomeSecurityStatus() {
        resetLockStatus()
        resetTemperatureStatus()
        refreshSuccessIndicatorHealth()
    }

    private func resetLockStatus() {
        lockLoadGeneration &+= 1
        pendingLockReadIDs = nil
        lockValuesByID = [:]
        lockIndicatorState = .loading
    }

    private func resetTemperatureStatus() {
        temperatureLoadGeneration &+= 1
        pendingTemperatureReadIDs = nil
        temperatureValuesByID = [:]
        temperatureIndicatorState = .loading
    }

    private func serviceHomeSecurity() {
        let canLoad = HomeSecurityReadPolicy.shouldLoad(
            hasVisibleCameras: !wallFeeds.isEmpty,
            allVisibleCamerasTrusted: allVisibleFeedsTrusted(at: Date())
        )
        guard canLoad else { return }

        if preferences.isLockStatusEnabled, pendingLockReadIDs == nil {
            beginLockStatusLoad()
        }
        if preferences.isHomeTemperatureEnabled, pendingTemperatureReadIDs == nil {
            beginTemperatureLoad()
        }
    }

    private func beginLockStatusLoad() {
        let selectedIDs = selectedCurrentHomeLockIDs
        pendingLockReadIDs = selectedIDs
        lockValuesByID = [:]
        refreshLockIndicator()

        for id in selectedIDs {
            guard let characteristic = lockCharacteristicsByID[id] else { continue }
            observe(characteristic)
            let sessionGeneration = self.sessionGeneration
            let loadGeneration = lockLoadGeneration
            characteristic.readValue { [weak self, weak characteristic] error in
                let succeeded = error == nil
                Task { @MainActor [weak self, weak characteristic] in
                    guard let self,
                          let characteristic,
                          self.acceptsCallback(generation: sessionGeneration),
                          self.lockLoadGeneration == loadGeneration,
                          self.lockCharacteristicsByID[id] === characteristic,
                          self.pendingLockReadIDs?.contains(id) == true else { return }

                    if succeeded, let value = characteristic.value as? NSNumber {
                        self.lockValuesByID[id] = value.intValue
                    } else {
                        self.lockValuesByID.removeValue(forKey: id)
                    }
                    self.pendingLockReadIDs?.remove(id)
                    self.refreshLockIndicator()
                }
            }
        }
    }

    private func beginTemperatureLoad() {
        let selectedIDs = selectedCurrentHomeTemperatureIDs
        pendingTemperatureReadIDs = selectedIDs
        temperatureValuesByID = [:]
        refreshTemperatureIndicator()

        for id in selectedIDs {
            guard let characteristic = temperatureCharacteristicsByID[id] else { continue }
            observe(characteristic)
            let sessionGeneration = self.sessionGeneration
            let loadGeneration = temperatureLoadGeneration
            characteristic.readValue { [weak self, weak characteristic] error in
                let succeeded = error == nil
                Task { @MainActor [weak self, weak characteristic] in
                    guard let self,
                          let characteristic,
                          self.acceptsCallback(generation: sessionGeneration),
                          self.temperatureLoadGeneration == loadGeneration,
                          self.temperatureCharacteristicsByID[id] === characteristic,
                          self.pendingTemperatureReadIDs?.contains(id) == true else { return }

                    if succeeded, let value = characteristic.value as? NSNumber {
                        self.temperatureValuesByID[id] = value.doubleValue
                    } else {
                        self.temperatureValuesByID.removeValue(forKey: id)
                    }
                    self.pendingTemperatureReadIDs?.remove(id)
                    self.refreshTemperatureIndicator()
                }
            }
        }
    }

    private func observe(_ characteristic: HMCharacteristic) {
        guard characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
              !characteristic.isNotificationEnabled else { return }
        characteristic.enableNotification(true) { _ in }
    }

    private func refreshLockIndicator() {
        if preferences.isLockStatusEnabled {
            lockIndicatorState = HomeSecurityStatusPolicy.lockState(
                isLoading: pendingLockReadIDs == nil || pendingLockReadIDs?.isEmpty == false,
                selectedIDs: selectedCurrentHomeLockIDs,
                valuesByID: lockValuesByID
            )
        } else {
            lockIndicatorState = .loading
        }
        refreshSuccessIndicatorHealth()
    }

    private func refreshTemperatureIndicator() {
        if preferences.isHomeTemperatureEnabled {
            temperatureIndicatorState = HomeSecurityStatusPolicy.temperatureState(
                isLoading: pendingTemperatureReadIDs == nil || pendingTemperatureReadIDs?.isEmpty == false,
                selectedIDs: selectedCurrentHomeTemperatureIDs,
                celsiusValuesByID: temperatureValuesByID,
                lowFahrenheit: preferences.homeTemperatureLowFahrenheit,
                highFahrenheit: preferences.homeTemperatureHighFahrenheit
            )
        } else {
            temperatureIndicatorState = .loading
        }
        refreshSuccessIndicatorHealth()
    }

    private func refreshSuccessIndicatorHealth(at date: Date = Date()) {
        let isHealthy: Bool
        if isAppActive, !wallFeeds.isEmpty {
            isHealthy = SuccessIndicatorPolicy.isHealthy(
                hasVisibleCameras: true,
                allVisibleCamerasReady: allVisibleFeedsTrusted(at: date),
                isLockStatusEnabled: preferences.isLockStatusEnabled,
                lockState: lockIndicatorState,
                isHomeTemperatureEnabled: preferences.isHomeTemperatureEnabled,
                temperatureState: temperatureIndicatorState
            )
        } else {
            isHealthy = false
        }

        guard isSuccessIndicatorHealthy != isHealthy else { return }
        isSuccessIndicatorHealthy = isHealthy
    }

    @discardableResult
    private func refreshHomeSecurityValue(for characteristic: HMCharacteristic) -> Bool {
        if let id = lockCharacteristicsByID.first(where: { $0.value === characteristic })?.key,
           pendingLockReadIDs != nil {
            if let value = characteristic.value as? NSNumber {
                lockValuesByID[id] = value.intValue
            } else {
                lockValuesByID.removeValue(forKey: id)
            }
            refreshLockIndicator()
            return true
        }

        if let id = temperatureCharacteristicsByID.first(where: { $0.value === characteristic })?.key,
           pendingTemperatureReadIDs != nil {
            if let value = characteristic.value as? NSNumber {
                temperatureValuesByID[id] = value.doubleValue
            } else {
                temperatureValuesByID.removeValue(forKey: id)
            }
            refreshTemperatureIndicator()
            return true
        }

        return false
    }

    private func resetSelectedHomeSecurityStatus(for accessory: HMAccessory) {
        let serviceIDs = Set(accessory.services.map { $0.uniqueIdentifier.uuidString })
        if !serviceIDs.isDisjoint(with: selectedCurrentHomeLockIDs) {
            resetLockStatus()
        }
        if !serviceIDs.isDisjoint(with: selectedCurrentHomeTemperatureIDs) {
            resetTemperatureStatus()
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
            self.refreshHomeSecurityValue(for: characteristic)
            let matchingFeeds = self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }
            matchingFeeds.forEach {
                $0.refreshHomeKitCameraActiveStateIfNeeded(for: characteristic)
                $0.refreshBatteryPercentageIfNeeded(for: characteristic)
            }
            if !matchingFeeds.isEmpty {
                self.refreshPresentation(focusedFeedID: self.focusedFeedID)
            }
        }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.resetSelectedHomeSecurityStatus(for: accessory)
            self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }.forEach { feed in
                feed.refreshSessionAvailabilityFromAccessory()
                guard var state = self.feedScheduleStates[feed.id] else { return }
                state.batteryWakeLeaseStartedAt = nil
                state.batteryWakeRetryAfter = nil
                if case .queued(let priority, _) = state.snapshotWorkState {
                    state.snapshotWorkState = .queued(priority: priority, eligibleAt: .distantPast)
                }
                self.feedScheduleStates[feed.id] = state
            }

            let visibleCount = self.wallFeeds.count
            self.liveCapacity = min(self.liveCapacity, visibleCount)
            if visibleCount == 0 {
                self.liveCapacityIncludesUnconfirmedMemory = false
                self.startupCoverageActive = true
                self.isDiscoveringRestrictedLiveCapacity = false
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

extension HomeKitCameraStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.refreshCurrentWiFiSSID()
            case .denied, .restricted:
                self.currentWiFiSSID = nil
                self.updateConnectionMode(at: Date(), refreshPresentation: true)
            case .notDetermined:
                break
            @unknown default:
                self.currentWiFiSSID = nil
                self.updateConnectionMode(at: Date(), refreshPresentation: true)
            }
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
    var startupState: StartupCameraState
}
