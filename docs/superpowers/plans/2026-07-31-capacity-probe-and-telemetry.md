# Capacity Probe and Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent same-camera snapshot/live-probe overlap and make startup telemetry accurately describe the policies it measures.

**Architecture:** Put snapshot-aware filtering in `LiveAdmissionController`, where optional probe admission already occurs, and pass the existing scheduler state through `LiveIntent`. Preserve ramp behavior while renaming its session-relative inputs. Keep reporting changes in `CameraTelemetry` and derive lifecycle-aware values in `HomeKitCameraStore`.

**Tech Stack:** Swift, XCTest, SwiftUI/HomeKit orchestration, Xcode Mac Catalyst and iPhone Simulator test destinations.

## Global Constraints

- Work directly on `main`.
- Do not commit.
- Do not change the ten-second live-capacity expansion cooldown.
- Keep `LOGIC.md` accurate and authoritative; leave it unchanged because behavior remains consistent.
- Preserve Wi-Fi burst, cellular startup ordering, snapshot concurrency, live capacity learning, and battery capture behavior.

---

### Task 1: Snapshot-Aware Capacity-Probe Admission

**Files:**
- Modify: `Observe/CameraLiveAdmissionController.swift`
- Modify: `Observe/HomeKitCameraStore.swift`
- Test: `ObserveTests/CameraLiveAdmissionTests.swift`

**Interfaces:**
- `LiveIntent.hasOutstandingSnapshot: Bool`
- `LiveAdmissionController.deferredCapacityProbeIDs: [String]`
- `LiveAdmissionController.reconcile(...) -> LiveAdmissionDecision`

- [ ] **Step 1: Add a failing controller regression test**

Construct two streaming steady-state intents, one capacity-probe intent with
`hasOutstandingSnapshot: true`, and one eligible capacity-probe intent. Assert
that the busy probe is absent from targets and starts, the eligible probe starts,
and `deferredCapacityProbeIDs` contains only the busy feed.

- [ ] **Step 2: Run the focused test and verify the new assertions fail**

Run:

```bash
xcodebuild test -project Observe.xcodeproj -scheme Observe -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:ObserveTests/CameraLiveAdmissionTests
```

Expected: failure because `LiveIntent` and the controller do not yet expose or
honor outstanding snapshot work.

- [ ] **Step 3: Implement candidate-local probe deferral**

Add the snapshot state to `LiveIntent`. In `reconcile`, record and exclude only
desired `.capacityProbe` intents with outstanding snapshot ownership. Pass
`snapshotWorkState.isOutstanding` from `HomeKitCameraStore`.

- [ ] **Step 4: Expose the deferral through bounded live-plan telemetry**

Add the deferred ID list to the existing live-plan signature and the top-level
telemetry report. Do not emit a new event on every refresh.

- [ ] **Step 5: Run the focused controller tests and verify they pass**

Run the command from Step 2 and require exit code 0.

### Task 2: Session-Relative Live-Ramp Naming

**Files:**
- Modify: `Observe/CameraStartupPolicies.swift`
- Modify: `Observe/HomeKitCameraStore.swift`
- Modify: `Observe/CameraTelemetry.swift`
- Test: `ObserveTests/CameraStartupTests.swift`
- Test: `ObserveTests/CameraTelemetryTests.swift`

**Interfaces:**
- `StartupLiveRampState.recordLiveStarted(feedID:sessionElapsed:fastSessionThreshold:)`
- `CameraTelemetryReport.startupLiveRampFastSessionThreshold`

- [ ] **Step 1: Add failing telemetry-format assertions**

Require `startupLiveRampFastSessionThreshold=3.0s` and
`sessionElapsed=... fastSessionThreshold=...` terminology, and reject the old
ambiguous threshold label.

- [ ] **Step 2: Run focused startup and telemetry tests and verify failure**

Run:

```bash
xcodebuild test -project Observe.xcodeproj -scheme Observe -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:ObserveTests/CameraStartupTests -only-testing:ObserveTests/CameraTelemetryTests
```

Expected: format assertions fail because the old `elapsed` and
`startupLiveRampFastThreshold` names remain.

- [ ] **Step 3: Rename the session-relative API and report fields**

Keep the comparison and pending-start limits unchanged. Update the event to
state `sessionElapsed` and `fastSessionThreshold` explicitly.

- [ ] **Step 4: Run focused startup and telemetry tests and verify they pass**

Run the command from Step 2 and require exit code 0.

### Task 3: Telemetry Lifecycle Clarity

**Files:**
- Modify: `Observe/CameraTelemetry.swift`
- Modify: `Observe/HomeKitCameraStore.swift`
- Test: `ObserveTests/CameraTelemetryTests.swift`
- Test: `ObserveTests/CameraStartupTests.swift`

**Interfaces:**
- Report text key `firstPassRecoveryFeedIDs`
- Metadata admission state `complete`
- Battery capture schedule label `coveredByLive`

- [ ] **Step 1: Add failing report-format and policy assertions**

Assert the historical first-pass recovery label, completed metadata state, and
live battery capture coverage label. Assert that a live battery feed does not
report a due countdown.

- [ ] **Step 2: Run focused tests and verify the expected failures**

Use the focused command from Task 2.

- [ ] **Step 3: Implement lifecycle-aware report values**

Rename only the rendered recovery key. Derive metadata `complete` after work has
finished. For live battery feeds, report `coveredByLive` and no countdown; retain
existing countdown behavior when not live.

- [ ] **Step 4: Update the stable telemetry fingerprint and verify focused tests**

Change the fingerprint only after inspecting the complete intended report diff,
then rerun the focused command with exit code 0.

### Task 4: Full Verification

**Files:**
- Verify all modified source, tests, and documentation.

**Interfaces:**
- No new interfaces.

- [ ] **Step 1: Run the complete Mac Catalyst suite**

```bash
xcodebuild test -project Observe.xcodeproj -scheme Observe -destination 'platform=macOS,variant=Mac Catalyst'
```

- [ ] **Step 2: Run the complete iPhone Simulator suite**

Resolve an installed iPhone Simulator destination with `xcodebuild
-showdestinations`, then run the full `Observe` scheme against that destination.

- [ ] **Step 3: Validate project and diff integrity**

```bash
plutil -lint Observe.xcodeproj/project.pbxproj
git diff --check
git status --short
git diff --stat
```

- [ ] **Step 4: Review the final diff against the approved design**

Confirm the cooldown, capacity learning, snapshot concurrency, network policy,
and `LOGIC.md` are unchanged. Leave all work uncommitted.
