# Camera Live Policy Regression Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore reliable optimistic battery live video, strict Restricted Mode priority behavior, and bounded capacity retries without reintroducing the startup request burst.

**Architecture:** Keep the universal first-image phase and one-at-a-time post-coverage ramp. Correct the policy boundaries: battery startup trust requires an Observe-captured still, optimistic mode targets every visible feed, the ramp preserves and admits every feed in UI order, and a constrained signal reduces runtime capacity to surviving streams before any delayed probe.

**Tech Stack:** Swift, SwiftUI Observation, HomeKit, XCTest, XcodeBuild.

## Global Constraints

- `LOGIC.md` remains authoritative and must describe the final behavior.
- Preserve first-image snapshot concurrency and one-at-a-time live admission.
- Do not silently hide HomeKit failures or add fallback images.
- Work directly on `main`; do not create a branch.

---

### Task 1: Encode the regressions

**Files:**
- Modify: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Consumes: `CameraRecoveryPlanner.makePlan`, `PostCoverageLiveRampPolicy.nextSelection`, `RestrictedLiveCapacity.afterConstrainedSignal`.
- Produces: tests proving optimistic all-feed live selection, battery-aware ramp preservation, battery live-start trust gating, strict priority after capacity reduction, and reduction to surviving capacity.

- [ ] Change the optimistic planner test to require every visible feed, including a trusted battery feed, to use `.live`.
- [ ] Add a ramp test where an already-streaming battery feed remains selected while the next UI-priority feed is admitted.
- [ ] Add a pure startup trust test requiring wired live-start to resolve coverage and battery live-start to remain pending.
- [ ] Add capacity tests requiring a rejected three-slot plan with two surviving streams to reduce to two, and a zero-survivor rejection to retain only the one-slot discovery fallback.
- [ ] Add a constrained planner assertion that the reduced capacity selects the exact UI-priority prefix.
- [ ] Run the selected tests and confirm failures match the current regressions.

### Task 2: Repair live and trust policy

**Files:**
- Modify: `Observe/CameraRecoveryPlanner.swift`
- Modify: `Observe/HomeKitCameraStore.swift`

**Interfaces:**
- Produces: `StartupCoverageTrustPolicy.resolvesOnLiveStart(isBatteryCamera:) -> Bool`.
- Changes: optimistic selection targets all feed IDs; ramp eligibility includes all feeds; ramp seeding includes all currently streaming feeds.

- [ ] Add the pure trust policy and use it in `handleLiveTransportEvent` so battery live-start does not resolve startup coverage.
- [ ] Make optimistic live selection include every visible feed while tagging due battery feeds for trusted-still capture within their live streams.
- [ ] Include battery feeds in ramp eligibility, completion, and initial working-stream preservation.
- [ ] Keep the existing one-additional-stream admission rule and focused-feed override.
- [ ] Run the focused tests and confirm they pass.

### Task 3: Repair constrained capacity and retry behavior

**Files:**
- Modify: `Observe/HomeKitCameraStore.swift`

**Interfaces:**
- Changes: `RestrictedLiveCapacity.afterConstrainedSignal` returns bounded surviving capacity rather than retaining rejected planned capacity.

- [ ] Reduce runtime capacity to `currentLiveCount`, bounded to visible feeds, after a constrained signal.
- [ ] Preserve a one-slot discovery fallback only when visible feeds exist and no stream currently reports live.
- [ ] Keep `liveCapacityExpansionBlockedUntil` as the sole gate for the next one-slot probe.
- [ ] Confirm the focused capacity and priority tests pass.

### Task 4: Audit lifecycle cleanup and documentation

**Files:**
- Modify: `LOGIC.md`
- Review: `Observe/HomeKitCameraStore.swift`
- Review: `Observe/CameraFeedCoordinator.swift`

**Interfaces:**
- Produces: authoritative documented optimistic, startup trust, ramp, and capacity semantics.

- [ ] Verify trusted-still capture clears its wake lease without stopping an optimistic live stream.
- [ ] Verify transition into Restricted Mode may stop a low-priority battery stream only when priority/capture rules require it.
- [ ] Verify expected intentional stop callbacks remain non-errors.
- [ ] Update `LOGIC.md` to restore all-camera optimistic live behavior and document battery trust and capacity downgrade rules.

### Task 5: Full verification

**Files:**
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Produces: fresh regression, platform-build, and diff-hygiene evidence.

- [ ] Run all Mac Catalyst tests with `xcodebuild -project Observe.xcodeproj -scheme Observe -destination 'platform=macOS,variant=Mac Catalyst' test`; require zero failures.
- [ ] Build generic iOS Simulator with `xcodebuild -project Observe.xcodeproj -scheme Observe -destination 'generic/platform=iOS Simulator' build`; require exit 0.
- [ ] Build generic iOS device with `xcodebuild -project Observe.xcodeproj -scheme Observe -destination 'generic/platform=iOS' build`; require exit 0.
- [ ] Run `git diff --check`; require no output and exit 0.
- [ ] Inspect the final diff and state real-device validation limitations explicitly.

### Task 6: Restore Fast LAN Fan-Out

**Files:**
- Modify: `Observe/CameraRecoveryPlanner.swift`
- Modify: `Observe/HomeKitCameraStore.swift`
- Modify: `ObserveTests/ObserveTests.swift`
- Modify: `LOGIC.md`

**Interfaces:**
- Produces: `StartupFastLocalLivePolicy.shouldActivate(liveStartedAtElapsed:threshold:) -> Bool`.
- Changes: startup always has one live transport probe; a probe live before three seconds selects normal all-visible optimistic live policy.

- [ ] Add failing tests for the strict three-second threshold and the no-battery wired probe.
- [ ] Start one UI-priority wired probe when no battery capture supplies the probe.
- [ ] Activate all-visible optimistic live selection only when a probe starts before three seconds.
- [ ] Ensure a constrained signal clears the fast-path state.
- [ ] Expose the fast-path state and threshold in telemetry.
- [ ] Update `LOGIC.md` and rerun all verification commands from Task 5.
