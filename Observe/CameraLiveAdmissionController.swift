import Foundation

enum LiveIntentRole: Equatable {
    case focused
    case batteryCapture
    case firstImageRecovery
    case steadyState
    case capacityProbe

    fileprivate var rank: Int {
        switch self {
        case .focused: 0
        case .batteryCapture: 1
        case .firstImageRecovery: 2
        case .steadyState: 3
        case .capacityProbe: 4
        }
    }
}

struct LiveIntent: Equatable {
    let id: String
    let role: LiveIntentRole
    let priorityIndex: Int
    let isDesired: Bool

    init(id: String, role: LiveIntentRole, priorityIndex: Int, isDesired: Bool = true) {
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
    case wifiBurst
    case adaptive(maxPendingStarts: Int)
    case constrained

    fileprivate var maximumPendingStarts: Int {
        switch self {
        case .wifiBurst:
            Int.max
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

struct LiveSoftContentionOutcome: Equatable {
    let attempt: Int
    let retryDelay: TimeInterval
    let sessionCeiling: Int
    let shouldYieldCamera: Bool
}

struct LiveAdmissionController {
    private(set) var mode: LiveAdmissionMode
    private(set) var sustainableCapacity: Int
    private(set) var softContentionSessionCeiling: Int?
    private(set) var activeCapacityProbeFeedID: String?
    private(set) var lastPlannerCapacity: Int?
    private(set) var lastEffectiveCapacity: Int?
    private(set) var lastCapacityLimitReason = "notEvaluated"

    private var contentionCountsByFeedID: [String: Int] = [:]
    private var failureCountsByFeedID: [String: Int] = [:]
    private var retryAfterByFeedID: [String: Date] = [:]
    private var activeCapacityProbeTarget: Int?
    private var infrastructureFailureCount = 0
    private var infrastructureRetryAfter: Date?

    init(mode: LiveAdmissionMode, sustainableCapacity: Int) {
        self.mode = mode
        self.sustainableCapacity = max(0, sustainableCapacity)
    }

    mutating func update(mode: LiveAdmissionMode, sustainableCapacity: Int) {
        self.mode = mode
        self.sustainableCapacity = max(0, sustainableCapacity)
    }

    @discardableResult
    mutating func recordSoftContention(
        feedID: String,
        survivingStreamCount: Int,
        at now: Date
    ) -> LiveSoftContentionOutcome {
        mode = .constrained
        clearCapacityProbeIfMatching(feedID)
        let failureCount = contentionCountsByFeedID[feedID, default: 0] + 1
        contentionCountsByFeedID[feedID] = failureCount
        let retryDelay = Self.retryDelay(failureCount: failureCount, delays: [1, 2, 4, 8])
        retryAfterByFeedID[feedID] = now.addingTimeInterval(retryDelay)

        if softContentionSessionCeiling == nil {
            softContentionSessionCeiling = max(1, survivingStreamCount)
        }

        return LiveSoftContentionOutcome(
            attempt: failureCount,
            retryDelay: retryDelay,
            sessionCeiling: softContentionSessionCeiling ?? 1,
            shouldYieldCamera: failureCount >= 2
        )
    }

    mutating func recordRetryableFailure(feedID: String, at now: Date) {
        clearCapacityProbeIfMatching(feedID)
        let failureCount = failureCountsByFeedID[feedID, default: 0] + 1
        failureCountsByFeedID[feedID] = failureCount
        retryAfterByFeedID[feedID] = now.addingTimeInterval(
            Self.retryDelay(failureCount: failureCount, delays: [2, 4, 8, 10])
        )
    }

    mutating func recordInfrastructureUnavailable(at now: Date) {
        infrastructureFailureCount += 1
        infrastructureRetryAfter = now.addingTimeInterval(
            Self.retryDelay(failureCount: infrastructureFailureCount, delays: [2, 4, 8, 10])
        )
    }

    mutating func recordSuccess(feedID: String) {
        if activeCapacityProbeFeedID == feedID {
            softContentionSessionCeiling = max(
                softContentionSessionCeiling ?? 0,
                activeCapacityProbeTarget ?? 0
            )
            activeCapacityProbeFeedID = nil
            activeCapacityProbeTarget = nil
        }
        contentionCountsByFeedID[feedID] = nil
        failureCountsByFeedID[feedID] = nil
        retryAfterByFeedID[feedID] = nil
        infrastructureFailureCount = 0
        infrastructureRetryAfter = nil
    }

    mutating func cancelCapacityProbe(feedID: String) {
        clearCapacityProbeIfMatching(feedID)
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
        preserveActiveDuringCoverage: Bool,
        plannerCapacity: Int? = nil,
        now: Date
    ) -> LiveAdmissionDecision {
        let sortedIntents = intents.sorted(by: Self.intentPrecedes)
        let desired = sortedIntents.filter(\.isDesired)
        let infrastructureIsEligible = infrastructureRetryAfter.map { now >= $0 } ?? true
        let targetEligibleDesired = desired.filter { intent in
            (transports[intent.id] ?? .idle) != .idle
                || (infrastructureIsEligible && isRetryEligible(feedID: intent.id, at: now))
        }
        let plannedCapacity = mode == .wifiBurst
            ? desired.count
            : max(0, plannerCapacity ?? sustainableCapacity)
        let capacity: Int
        if mode == .wifiBurst {
            capacity = plannedCapacity
            lastCapacityLimitReason = "wifiBurst"
        } else if let sessionCeiling = softContentionSessionCeiling {
            let hasExplicitCapacityProbe = targetEligibleDesired.contains { intent in
                intent.role == .capacityProbe
                    && (activeCapacityProbeFeedID == nil || activeCapacityProbeFeedID == intent.id)
            }
            let probeAllowance = hasExplicitCapacityProbe && plannedCapacity > sessionCeiling ? 1 : 0
            capacity = min(plannedCapacity, sessionCeiling + probeAllowance)
            if probeAllowance == 1 {
                lastCapacityLimitReason = "softContentionProbe"
            } else if plannedCapacity > sessionCeiling {
                lastCapacityLimitReason = "softContentionCeiling"
            } else {
                lastCapacityLimitReason = "plannerWithinSoftContentionCeiling"
            }
        } else {
            capacity = plannedCapacity
            lastCapacityLimitReason = "planner"
        }
        lastPlannerCapacity = plannedCapacity
        lastEffectiveCapacity = capacity

        var targets: [LiveIntent] = []
        func appendIfAbsent(_ intent: LiveIntent) {
            guard targets.count < capacity, !targets.contains(where: { $0.id == intent.id }) else { return }
            targets.append(intent)
        }

        if preserveActiveDuringCoverage || !infrastructureIsEligible {
            for intent in targetEligibleDesired where intent.role != .steadyState {
                appendIfAbsent(intent)
            }
            for intent in sortedIntents where transports[intent.id] == .streaming {
                appendIfAbsent(intent)
            }
        }
        for intent in targetEligibleDesired {
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

        if activeCapacityProbeFeedID == nil,
           let admittedProbe = targets.first(where: { intent in
               intent.role == .capacityProbe && startIDs.contains(intent.id)
           }) {
            activeCapacityProbeFeedID = admittedProbe.id
            activeCapacityProbeTarget = capacity
        }

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

    private mutating func clearCapacityProbeIfMatching(_ feedID: String) {
        guard activeCapacityProbeFeedID == feedID else { return }
        activeCapacityProbeFeedID = nil
        activeCapacityProbeTarget = nil
    }

    private static func retryDelay(failureCount: Int, delays: [TimeInterval]) -> TimeInterval {
        delays[min(max(0, failureCount - 1), delays.count - 1)]
    }

    private static func intentPrecedes(_ lhs: LiveIntent, _ rhs: LiveIntent) -> Bool {
        if lhs.role.rank != rhs.role.rank { return lhs.role.rank < rhs.role.rank }
        if lhs.priorityIndex != rhs.priorityIndex { return lhs.priorityIndex < rhs.priorityIndex }
        return lhs.id < rhs.id
    }
}
