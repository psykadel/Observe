# Startup Camera State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace parallel startup flags with one tested per-camera state machine and reject stale HomeKit session callbacks.

**Architecture:** Add a pure `StartupCameraState` transition model beside the recovery planner. Store one instance in `FeedScheduleState`, derive planner fields from it, and capture a store session generation in every feed callback closure.

**Tech Stack:** Swift, HomeKit, XCTest, Xcode

## Global Constraints

- Preserve the complete behavior documented by `LOGIC.md`.
- Preserve the fast-LAN path, Restricted Mode priority, battery trusted-still requirement, and late snapshot success acceptance.
- Do not move snapshot scheduler or battery lease state into the startup state machine.
- Work directly on `main` according to repository instructions.

---

### Task 1: Pure Startup State Machine

**Files:**
- Modify: `Observe/CameraRecoveryPlanner.swift`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Produces: `StartupCameraState.apply(_:isBatteryCamera:)`
- Produces: derived `resolution`, `snapshotAttempted`, `snapshotFailed`, `liveAttempted`, and `liveFallbackStartedAt`

- [ ] Add failing tests for wired dual-path failure, battery live behavior, trusted transitions, and accepted late success.
- [ ] Run focused tests and verify failure because `StartupCameraState` does not exist.
- [ ] Implement the minimal transition model.
- [ ] Run focused tests and verify they pass.

### Task 2: Session Generation Guard

**Files:**
- Modify: `Observe/HomeKitCameraStore.swift`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Produces: `CameraSessionGeneration.accepts(callbackGeneration:activeGeneration:)`
- Adds: `sessionGeneration` to `HomeKitCameraStore`

- [ ] Add a failing test proving old generations are rejected and the active generation is accepted.
- [ ] Run the focused test and verify failure because the policy does not exist.
- [ ] Implement the policy, increment generation before rebuild/invalidation, and capture it in feed callbacks.
- [ ] Guard snapshot, live, constrained, and availability callback handlers.
- [ ] Run focused tests and verify they pass.

### Task 3: Store Integration and Flag Removal

**Files:**
- Modify: `Observe/HomeKitCameraStore.swift`
- Modify: `Observe/CameraRecoveryPlanner.swift`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Replaces: six startup fields in `FeedScheduleState` with `startupState: StartupCameraState`
- Preserves: existing `FeedPlanningSnapshot` derived inputs

- [ ] Change test helpers to construct the state machine and verify compilation fails against the old initializer.
- [ ] Route request, callback, timeout, battery, fallback, trusted-image, reset, and availability transitions through `apply`.
- [ ] Delete direct startup flag and resolution mutations.
- [ ] Extend telemetry with snapshot-path and live-path labels from the state machine.
- [ ] Run all planner and telemetry tests.

### Task 4: Documentation and Verification

**Files:**
- Modify: `LOGIC.md`

**Interfaces:**
- Documents: one startup authority and stale-session callback rejection

- [ ] Update `LOGIC.md` with the state-machine and generation invariants.
- [ ] Run the complete Mac Catalyst test suite.
- [ ] Build generic iOS Simulator and generic iOS device destinations.
- [ ] Run `git diff --check` and search for removed parallel startup fields.
