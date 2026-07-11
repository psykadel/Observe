# Internal Snapshot Concurrency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Snapshot Requests user setting and make concurrency an internal Observe scheduling policy.

**Architecture:** Keep concurrency policy in `CameraSchedulingDefaults` and `StartupSnapshotConcurrencyPolicy`. Remove persistence and UI plumbing, then make `HomeKitCameraStore` consume only the internal policy and expose explicit internal/effective values in telemetry.

**Tech Stack:** Swift, SwiftUI, XCTest, HomeKit, Xcode

## Global Constraints

- `LOGIC.md` remains authoritative and must be updated with the internal limits.
- The legacy UserDefaults value must not affect scheduling.
- Startup active limits remain two before the first trusted non-battery image and three afterward.
- Startup outstanding limit remains four; steady-state active and outstanding limits remain three.

---

### Task 1: Remove preference and settings surface

**Files:**
- Modify: `Observe/ObservePreferences.swift`
- Modify: `Observe/SettingsView.swift`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Removes: `ObservePreferences.maxConcurrentSnapshotRequests`, `setMaxConcurrentSnapshotRequests(_:)`, and `NumberSettingKind.maxConcurrentSnapshotRequests`
- Preserves: all other number-setting behavior

- [ ] Write tests that no longer set or assert the snapshot preference and that enumerate exactly the supported number-setting cases.
- [ ] Run the focused tests and verify they fail while the obsolete case remains.
- [ ] Delete the UserDefaults key, property, initializer read, setter, settings section, binding, and enum branches.
- [ ] Run the focused tests and verify they pass.

### Task 2: Internalize scheduler limits and telemetry

**Files:**
- Modify: `Observe/CameraModels.swift`
- Modify: `Observe/CameraRecoveryPlanner.swift`
- Modify: `Observe/HomeKitCameraStore.swift`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Produces: `CameraSchedulingDefaults.maxConcurrentSnapshotRequests == 3` as an internal constant
- Changes: `StartupSnapshotConcurrencyPolicy.effectiveLimit(isFirstFramePhaseActive:nonBatteryTrustedCount:nonBatteryCount:)`
- Changes: telemetry field to `internalMaxConcurrentSnapshotRequests`

- [ ] Change tests to call concurrency policy without a configured-limit argument and expect two-to-three startup adaptation plus three at steady state.
- [ ] Run focused tests and verify compilation fails on the old signature.
- [ ] Remove the configured-limit parameter and use the internal ceiling.
- [ ] Update store admission and telemetry to use only the internal ceiling.
- [ ] Run focused tests and verify they pass.

### Task 3: Documentation and complete verification

**Files:**
- Modify: `LOGIC.md`

**Interfaces:**
- Documents: internal two-to-three active policy, startup outstanding cap four, steady-state cap three

- [ ] Remove all references to a user-controlled snapshot limit from `LOGIC.md`.
- [ ] Run the full Mac Catalyst test suite.
- [ ] Build generic iOS Simulator and generic iOS device destinations.
- [ ] Run `git diff --check` and inspect the final diff for residual Snapshot Requests UI or persistence references.
