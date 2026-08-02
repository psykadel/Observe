import Foundation

enum LiveIntentRole: Equatable {
    case focused
    case batteryCapture
    case steadyState

    fileprivate var rank: Int {
        switch self {
        case .focused: 0
        case .batteryCapture: 1
        case .steadyState: 2
        }
    }
}

struct LiveIntent: Equatable {
    let id: String
    let role: LiveIntentRole
    let priorityIndex: Int
    let isDesired: Bool

    init(
        id: String,
        role: LiveIntentRole,
        priorityIndex: Int,
        isDesired: Bool = true
    ) {
        self.id = id
        self.role = role
        self.priorityIndex = priorityIndex
        self.isDesired = isDesired
    }
}

enum LiveTransportPhase: Equatable {
    case idle
    case starting
    case streaming
    case stopping

    var reservesCapacity: Bool {
        self != .idle
    }
}

enum LiveAdmissionMode: Equatable {
    case adaptive(maxPendingStarts: Int)
    case constrained

    fileprivate var maximumPendingStarts: Int {
        switch self {
        case .adaptive(let maximum):
            max(1, maximum)
        case .constrained:
            1
        }
    }
}

struct LiveAdmissionDecision: Equatable {
    let targetIDs: [String]
    let stopIDs: [String]
    let startIDs: [String]
    let queuedStartIDs: [String]
    let reservedTransportIDs: [String]
}

struct LiveAdmissionController {
    private(set) var mode: LiveAdmissionMode
    private(set) var sustainableCapacity: Int
    private(set) var lastPlannerCapacity: Int?
    private(set) var lastEffectiveCapacity: Int?
    private(set) var lastCapacityLimitReason = "notEvaluated"

    private var retryAfterByFeedID: [String: Date] = [:]
    private var infrastructureRetryAfter: Date?

    init(mode: LiveAdmissionMode, sustainableCapacity: Int) {
        self.mode = mode
        self.sustainableCapacity = max(0, sustainableCapacity)
    }

    mutating func update(mode: LiveAdmissionMode, sustainableCapacity: Int) {
        self.mode = mode
        self.sustainableCapacity = max(0, sustainableCapacity)
    }

    mutating func recordRetryableFailure(feedID: String, at now: Date) {
        retryAfterByFeedID[feedID] = now.addingTimeInterval(CameraSchedulingDefaults.failureRetryDelay)
    }

    mutating func recordInfrastructureUnavailable(at now: Date) {
        infrastructureRetryAfter = now.addingTimeInterval(CameraSchedulingDefaults.failureRetryDelay)
    }

    mutating func recordSuccess(feedID: String) {
        retryAfterByFeedID[feedID] = nil
        infrastructureRetryAfter = nil
    }

    func retryDelay(feedID: String, at now: Date) -> TimeInterval? {
        retryAfterByFeedID[feedID].map { max(0, $0.timeIntervalSince(now)) }
    }

    func infrastructureRetryDelay(at now: Date) -> TimeInterval? {
        infrastructureRetryAfter.map { max(0, $0.timeIntervalSince(now)) }
    }

    mutating func reconcile(
        intents: [LiveIntent],
        transports: [String: LiveTransportPhase],
        plannerCapacity: Int? = nil,
        now: Date
    ) -> LiveAdmissionDecision {
        let sortedIntents = intents.sorted(by: Self.intentPrecedes)
        let desired = sortedIntents.filter(\.isDesired)
        let infrastructureIsEligible = infrastructureRetryAfter.map { now >= $0 } ?? true
        let targetEligibleDesired = desired.filter { intent in
            if (transports[intent.id] ?? .idle) != .idle {
                return true
            }
            return infrastructureIsEligible && isRetryEligible(feedID: intent.id, at: now)
        }
        let plannedCapacity = max(0, plannerCapacity ?? sustainableCapacity)
        let capacity = plannedCapacity
        lastCapacityLimitReason = "planner"
        lastPlannerCapacity = plannedCapacity
        lastEffectiveCapacity = capacity

        var targets: [LiveIntent] = []
        func appendIfAbsent(_ intent: LiveIntent) {
            guard targets.count < capacity, !targets.contains(where: { $0.id == intent.id }) else { return }
            targets.append(intent)
        }

        for intent in targetEligibleDesired {
            appendIfAbsent(intent)
        }
        for intent in sortedIntents where transports[intent.id] == .streaming {
            appendIfAbsent(intent)
        }

        let targetIDs = targets.map(\.id)
        let targetSet = Set(targetIDs)
        let reservedTransportIDs = transports.compactMap { id, phase in
            phase.reservesCapacity ? id : nil
        }.sorted()
        let stopIDs = reservedTransportIDs.filter { !targetSet.contains($0) }
        let candidates = targets.filter { intent in
            (transports[intent.id] ?? .idle) == .idle && isRetryEligible(feedID: intent.id, at: now)
        }.map(\.id)

        guard stopIDs.isEmpty,
              !transports.values.contains(.stopping),
              infrastructureIsEligible else {
            return LiveAdmissionDecision(
                targetIDs: targetIDs,
                stopIDs: stopIDs,
                startIDs: [],
                queuedStartIDs: candidates,
                reservedTransportIDs: reservedTransportIDs
            )
        }

        let reservations = reservedTransportIDs.count
        let freeCapacity = max(0, capacity - reservations)
        let pendingStarts = transports.values.filter { $0 == .starting }.count
        let pendingStartAllowance = max(0, mode.maximumPendingStarts - pendingStarts)
        let admittedCount = min(candidates.count, freeCapacity, pendingStartAllowance)
        let startIDs = Array(candidates.prefix(admittedCount))
        let queuedStartIDs = Array(candidates.dropFirst(admittedCount))

        return LiveAdmissionDecision(
            targetIDs: targetIDs,
            stopIDs: stopIDs,
            startIDs: startIDs,
            queuedStartIDs: queuedStartIDs,
            reservedTransportIDs: reservedTransportIDs
        )
    }

    private func isRetryEligible(feedID: String, at now: Date) -> Bool {
        retryAfterByFeedID[feedID].map { now >= $0 } ?? true
    }

    private static func intentPrecedes(_ lhs: LiveIntent, _ rhs: LiveIntent) -> Bool {
        if lhs.role.rank != rhs.role.rank { return lhs.role.rank < rhs.role.rank }
        if lhs.priorityIndex != rhs.priorityIndex { return lhs.priorityIndex < rhs.priorityIndex }
        return lhs.id < rhs.id
    }
}
