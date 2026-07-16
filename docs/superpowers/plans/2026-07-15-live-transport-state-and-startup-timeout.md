# Live Transport State and Startup Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make live-capacity ownership independent from tile and snapshot presentation, and make a stalled wired startup live attempt yield after eight seconds without unsafe stop/start overlap.

**Architecture:** Add one pure `CameraLiveTransportState` lifecycle in `CameraTransportPolicies.swift` and make `CameraFeedCoordinator` use it as the only input to `LiveTransportPhase`. Keep `FeedDisplayState` presentation-only. Select the startup timeout with a small policy, classify timeout-requested stop callbacks distinctly, and let the existing startup state machine and retry controller move the camera to nonterminal recovery after HomeKit confirms the stop.

**Tech Stack:** Swift, SwiftUI, HomeKit, XCTest, Xcode project builds for Mac Catalyst and iPhone Simulator.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- `LOGIC.md` remains authoritative and must describe the final behavior.
- Wired live starts during startup coverage use an explicit 8-second deadline.
- Battery and ordinary post-startup live work retain the existing 30-second deadline.
- Snapshot activity and `FeedDisplayState` never reserve live capacity.
- Starting, streaming, and stopping reserve capacity; idle does not.
- A timeout requests one stop and waits for HomeKit confirmation before replacement.
- Do not change snapshot concurrency, battery capture, focused priority, capacity learning, or wall membership.

---

### Task 1: Encode the transport lifecycle and timeout policy

**Files:**
- Modify: `Observe/CameraSchedulingPolicies.swift`
- Modify: `Observe/CameraTransportPolicies.swift`
- Modify: `ObserveTests/CameraLiveAdmissionTests.swift`
- Modify: `ObserveTests/CameraStartupTests.swift`

**Interfaces:**
- Produces: `CameraSchedulingDefaults.wiredStartupLiveStartTimeout: TimeInterval`.
- Produces: `LiveStartTimeoutPolicy.timeout(startupCoverageActive:isBatteryCamera:) -> TimeInterval`.
- Produces: `CameraLiveStopReason` with `.planned` and `.startupTimeout`.
- Produces: `CameraLiveTransportState` with authoritative phase and timestamp accessors.
- Produces: `CameraLiveFailureDisposition.startupTimedOut`.
- Changes: `CameraLiveFailureDispositionPolicy.classify(error:stopReason:)` accepts explicit local stop intent.

- [ ] **Step 1: Add failing lifecycle and timeout tests**

Add these tests:

```swift
func testLiveTransportStateOwnsCapacityIndependentlyFromDisplayState() {
    var transport = CameraLiveTransportState.idle
    let display = FeedDisplayState.starting

    XCTAssertEqual(display, .starting)
    XCTAssertEqual(transport.phase, .idle)
    XCTAssertFalse(transport.phase.reservesCapacity)

    XCTAssertTrue(transport.requestStart(at: now))
    XCTAssertEqual(transport.phase, .starting)
    XCTAssertEqual(transport.startRequestedAt, now)
    XCTAssertTrue(transport.phase.reservesCapacity)

    XCTAssertTrue(transport.requestStop(at: now.addingTimeInterval(8), reason: .startupTimeout))
    XCTAssertEqual(transport.phase, .stopping)
    XCTAssertEqual(transport.stopReason, .startupTimeout)
    XCTAssertFalse(transport.requestStop(at: now.addingTimeInterval(9), reason: .startupTimeout))

    XCTAssertEqual(transport.confirmStopped(), .startupTimeout)
    XCTAssertEqual(transport, .idle)
}

func testLateStartWhileStoppingDoesNotRestoreStreamingOwnership() {
    var transport = CameraLiveTransportState.starting(requestedAt: now)
    _ = transport.requestStop(at: now.addingTimeInterval(8), reason: .startupTimeout)

    XCTAssertFalse(transport.confirmStarted(at: now.addingTimeInterval(8.1)))
    XCTAssertEqual(transport.phase, .stopping)
}

func testStartupLiveTimeoutPolicySeparatesWiredAndBatteryWork() {
    XCTAssertEqual(
        LiveStartTimeoutPolicy.timeout(startupCoverageActive: true, isBatteryCamera: false),
        8
    )
    XCTAssertEqual(
        LiveStartTimeoutPolicy.timeout(startupCoverageActive: true, isBatteryCamera: true),
        30
    )
    XCTAssertEqual(
        LiveStartTimeoutPolicy.timeout(startupCoverageActive: false, isBatteryCamera: false),
        30
    )
}
```

Extend stop-classification tests so nil or `operationCancelled` with `.startupTimeout` produces `.startupTimedOut`, `.planned` produces `.requestedStop`, and substantive HomeKit busy/capacity/transport errors retain their existing dispositions.

- [ ] **Step 2: Run focused tests and verify the new symbols fail to compile**

Run:

```bash
xcodebuild test -project Observe.xcodeproj -scheme Observe -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:ObserveTests/CameraLiveAdmissionTests -only-testing:ObserveTests/CameraStartupTests
```

Expected: failure because `CameraLiveTransportState`, `CameraLiveStopReason`, `LiveStartTimeoutPolicy`, and `.startupTimedOut` do not exist yet.

- [ ] **Step 3: Add the minimal pure implementation**

Add the explicit deadline and policy:

```swift
static let wiredStartupLiveStartTimeout: TimeInterval = 8

enum LiveStartTimeoutPolicy {
    static func timeout(startupCoverageActive: Bool, isBatteryCamera: Bool) -> TimeInterval {
        startupCoverageActive && !isBatteryCamera
            ? CameraSchedulingDefaults.wiredStartupLiveStartTimeout
            : CameraSchedulingDefaults.batteryWakeLiveStartTimeout
    }
}
```

Add the lifecycle beside the existing transport policies:

```swift
enum CameraLiveStopReason: Equatable {
    case planned
    case startupTimeout
}

enum CameraLiveTransportState: Equatable {
    case idle
    case starting(requestedAt: Date)
    case streaming(startedAt: Date)
    case stopping(requestedAt: Date, reason: CameraLiveStopReason)

    var phase: LiveTransportPhase {
        switch self {
        case .idle: .idle
        case .starting: .starting
        case .streaming: .streaming
        case .stopping: .stopping
        }
    }

    var startRequestedAt: Date? {
        guard case .starting(let requestedAt) = self else { return nil }
        return requestedAt
    }

    var startedAt: Date? {
        guard case .streaming(let startedAt) = self else { return nil }
        return startedAt
    }

    var stopRequestedAt: Date? {
        guard case .stopping(let requestedAt, _) = self else { return nil }
        return requestedAt
    }

    var stopReason: CameraLiveStopReason? {
        guard case .stopping(_, let reason) = self else { return nil }
        return reason
    }

    mutating func requestStart(at date: Date) -> Bool {
        guard case .idle = self else { return false }
        self = .starting(requestedAt: date)
        return true
    }

    mutating func confirmStarted(at date: Date) -> Bool {
        guard case .stopping = self else {
            self = .streaming(startedAt: date)
            return true
        }
        return false
    }

    mutating func requestStop(at date: Date, reason: CameraLiveStopReason) -> Bool {
        switch self {
        case .starting, .streaming:
            self = .stopping(requestedAt: date, reason: reason)
            return true
        case .idle, .stopping:
            return false
        }
    }

    mutating func confirmStopped() -> CameraLiveStopReason? {
        let reason = stopReason
        self = .idle
        return reason
    }
}
```

Add `.startupTimedOut` to `CameraLiveFailureDisposition`. Change classification to accept `stopReason: CameraLiveStopReason?`; map nil/cancellation plus `.startupTimeout` to `.startupTimedOut`, nil/cancellation plus `.planned` to `.requestedStop`, and evaluate every substantive HomeKit error with the existing evidence-based switch.

- [ ] **Step 4: Run focused tests and require success**

Run the Task 1 command again. Expected: all selected tests pass.

---

### Task 2: Make the coordinator lifecycle authoritative

**Files:**
- Modify: `Observe/CameraFeedCoordinator.swift`
- Modify: `Observe/HomeKitCameraStore.swift`
- Modify: `ObserveTests/CameraLiveAdmissionTests.swift`
- Modify: `ObserveTests/CameraStartupTests.swift`

**Interfaces:**
- Consumes: `CameraLiveTransportState`, `CameraLiveStopReason`, and `LiveStartTimeoutPolicy` from Task 1.
- Changes: `CameraFeedCoordinator.liveTransportPhase` maps only `liveTransportState.phase`.
- Changes: `CameraFeedCoordinator.stopLiveIfNeeded(reason:) -> Bool` requests at most one stop.
- Changes: `CameraLiveTransportEvent.stopRequested` includes its `CameraLiveStopReason`.
- Produces: timeout events flow through `.startupTimedOut` and existing startup recovery/backoff.

- [ ] **Step 1: Add failing admission and timeout-flow tests**

Add a controller test proving an idle transport leaves the next camera startable even when its tile would be loading, plus a stopping transport test proving replacement remains queued until `confirmStopped()` returns it to idle. Update existing stop event and failure-disposition expectations for the new explicit reason.

Replace the old “restart after 30 seconds” policy test with an assertion that startup timeout classification yields the camera rather than issuing an immediate restart.

- [ ] **Step 2: Run the focused tests and verify failure**

Run the Task 1 test command. Expected: compile/test failure because the coordinator and store still use legacy timestamps, a boolean stop marker, and immediate restart semantics.

- [ ] **Step 3: Replace overlapping coordinator state**

In `CameraFeedCoordinator`:

- Replace `liveStartRequestedAt`, `liveStartedAt`, `liveStopRequestedAt`, and `requestedStreamStop` storage with `private var liveTransportState = CameraLiveTransportState.idle`.
- Keep computed timestamp properties for existing planner and telemetry callers by reading the lifecycle.
- Define `isStartingLive` as `liveTransportState.phase == .starting`.
- Define `liveTransportPhase` as `liveTransportState.phase`; never inspect `FeedDisplayState`.
- Update `preferLive` so a new start first calls `requestStart`, emits one start event, and calls `startStream()` once. Remove the stop-and-immediately-restart branch.
- Update `stopLiveIfNeeded(reason: .planned)` to call `requestStop`; emit one reasoned stop event and call `stopStream()` only when that transition succeeds.
- On `cameraStreamControlDidStartStream`, call `confirmStarted`. Always accept the fresh image and emit the start callback, but do not leave `.stopping` if a late callback races a stop.
- On `didStopStreamWithError`, capture the lifecycle stop reason, call `confirmStopped()` before notifying the store, and classify with `error` plus the captured reason.
- Reset/offline paths clear or stop the lifecycle consistently without consulting tile state.

Snapshot methods may continue to set `FeedDisplayState.starting` for presentation, but must not mutate `liveTransportState`.

- [ ] **Step 4: Apply the startup-specific deadline in the store**

In `reconcileFeedScheduleStates`, select the deadline with:

```swift
let liveStartTimeout = LiveStartTimeoutPolicy.timeout(
    startupCoverageActive: startupCoverageActive,
    isBatteryCamera: preferences.isBatteryWakeCamera(id: feed.id)
)
```

When a nonstreaming startup fallback exceeds that deadline, call:

```swift
if feed.stopLiveIfNeeded(reason: .startupTimeout) {
    recordTelemetry(
        "startup live fallback timed out \(feed.id) elapsed=\(formatSeconds(now.timeIntervalSince(fallbackStartedAt)))"
    )
}
```

Do not mark the live path failed or restart before the stop callback. In `handleLiveTransportEvent`, treat `.startupTimedOut` as a live-path failure and retryable per-camera backoff, then refresh so pending first-pass cameras outrank the recovering camera. Preserve the existing handling of requested stops, contention, hard capacity, infrastructure, and transport errors.

- [ ] **Step 5: Run focused tests and require success**

Run the Task 1 command. Expected: all selected tests pass and no snapshot/display state can create a live reservation.

---

### Task 3: Make telemetry and LOGIC.md expose the boundary

**Files:**
- Modify: `Observe/CameraTelemetry.swift`
- Modify: `Observe/HomeKitCameraStore.swift`
- Modify: `ObserveTests/CameraTelemetryTests.swift`
- Modify: `LOGIC.md`

**Interfaces:**
- Adds report field: `wiredStartupLiveStartTimeout`.
- Adds per-feed fields: `liveTransportPhase`, `liveStopRequestedAge`, and `liveStopReason`.
- Preserves existing snapshot work and image milestone fields.

- [ ] **Step 1: Add failing telemetry assertions**

Extend the telemetry fixture with an idle live phase alongside `displayState: "starting"` and `snapshotWorkState: "active"`. Assert the report contains:

```text
wiredStartupLiveStartTimeout=8.0s
liveTransportPhase=idle
displayState=starting
snapshotWorkState=active
liveStopRequestedAge=nil
liveStopReason=nil
```

Update the expected stable telemetry fingerprint only after inspecting the complete generated report.

- [ ] **Step 2: Run the telemetry test and verify failure**

Run:

```bash
xcodebuild test -project Observe.xcodeproj -scheme Observe -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:ObserveTests/CameraTelemetryTests
```

Expected: compile/assertion failure because the report does not yet expose the new fields.

- [ ] **Step 3: Add report fields and update documentation**

Add the top-level wired startup deadline and the authoritative per-feed transport fields to `CameraTelemetryReport`, `CameraTelemetryFeed`, report construction, and text rendering. Keep `startingLive` for compatibility, but derive it only from the authoritative live lifecycle.

Update `LOGIC.md` in the startup coverage section to state:

- presentation and snapshot loading never reserve live capacity;
- wired first-image live starts time out after eight seconds;
- timeout requests one stop and waits for HomeKit confirmation;
- after release, the camera enters nonterminal recovery and pending first-pass cameras go first;
- battery live-start timeout remains 30 seconds.

- [ ] **Step 4: Run telemetry and focused behavior tests**

Run the Task 1 command plus the telemetry-only command. Expected: all selected tests pass.

---

### Task 4: Verify both platforms and commit the implementation

**Files:**
- Verify: `Observe.xcodeproj/project.pbxproj`
- Verify: all modified source, test, documentation, and plan files.

**Interfaces:**
- Produces: deterministic policy evidence on Mac Catalyst and iPhone Simulator.
- Leaves: real HomeKit callback timing for follow-up device telemetry.

- [ ] **Step 1: Lint project and diff**

Run:

```bash
plutil -lint Observe.xcodeproj/project.pbxproj
git diff --check
git status --short
```

Expected: project file reports `OK`, diff check emits no errors, and status lists only the intended implementation files.

- [ ] **Step 2: Run the full Mac Catalyst suite**

Run:

```bash
xcodebuild test -project Observe.xcodeproj -scheme Observe -destination 'platform=macOS,variant=Mac Catalyst'
```

Expected: `** TEST SUCCEEDED **` with zero failures.

- [ ] **Step 3: Run the full iPhone Simulator suite**

Run:

```bash
xcodebuild test -project Observe.xcodeproj -scheme Observe -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: `** TEST SUCCEEDED **` with zero failures.

- [ ] **Step 4: Review the final diff against the design**

Confirm the diff contains no concurrency increase, capacity-learning change, wall-membership change, UI redesign, or timer-based release of stopping capacity. Confirm `LOGIC.md` exactly matches the implementation.

- [ ] **Step 5: Commit**

Stage only the intended files and commit with:

```bash
git commit -m "🐛 fix: prevent stalled cameras blocking startup"
```

The commit subject is imperative, lower case, under nine words, and describes the user-visible correction.
