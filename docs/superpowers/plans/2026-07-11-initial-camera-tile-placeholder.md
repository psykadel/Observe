# Initial Camera Tile Placeholder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide stale or missing cached imagery behind a silent red camera placeholder only until the tile has a recent cached image or receives a fresh image in the current app session.

**Architecture:** Add explicit per-session freshness state to `CameraFeedCoordinator`, then centralize the launch-placeholder decision in a pure `InitialCameraTilePolicy`. `CameraTileView` consumes that decision without modifying the existing display classifier or scheduler.

**Tech Stack:** Swift, SwiftUI, HomeKit, XCTest, Xcode

## Global Constraints

- A cached snapshot within the existing camera stale threshold displays immediately.
- A stale or missing cached snapshot is hidden before the first fresh session image.
- The launch placeholder shows the existing camera icon, a red border, and no status row.
- Camera name and optional battery percentage remain visible.
- Existing behavior resumes unchanged after a fresh image or live stream arrives.
- Camera detail and camera scheduling behavior are out of scope.

---

### Task 1: Initial Tile Presentation Policy

**Files:**
- Modify: `Observe/CameraModels.swift`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Produces: `InitialCameraTilePolicy.presentation(hasFreshImageThisSession:displayedStillDate:staleThreshold:now:) -> InitialCameraTilePresentation`

- [ ] **Step 1: Write failing policy tests**

Add tests asserting that missing and stale cached images return true before freshness, while recent cached, fresh-session, and live inputs return false.

- [ ] **Step 2: Run the focused tests and verify RED**

Run the Mac Catalyst test target and expect compilation to fail because `InitialCameraTilePolicy` does not exist.

- [ ] **Step 3: Implement the minimal pure policy**

Return normal for cameras with a received fresh image; otherwise return the launch placeholder unless `displayedStillDate` exists and its nonnegative age is within `staleThreshold`.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Mac Catalyst test target and expect all policy cases to pass.

### Task 2: Per-Session Fresh Image State

**Files:**
- Modify: `Observe/CameraFeedCoordinator.swift`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Produces: `CameraFeedCoordinator.hasFreshImageThisSession: Bool`
- Consumes: New snapshot callbacks, current live stream sources, and existing session reset flow.

- [ ] **Step 1: Add a failing state-transition test where possible**

Verify the pure freshness-transition semantics or the closest coordinator seam available without mocking HomeKit objects.

- [ ] **Step 2: Run the test and verify RED**

Expect failure because the freshness state is not present.

- [ ] **Step 3: Implement minimal freshness tracking**

Initialize and reset the flag to false. Do not set it while presenting `mostRecentSnapshot`. Set it when a new snapshot callback is accepted or when a current live camera stream is established.

- [ ] **Step 4: Run the tests and verify GREEN**

Confirm the focused tests and existing camera coordinator policy tests pass.

### Task 3: Camera Wall Tile Integration

**Files:**
- Modify: `Observe/CameraTileView.swift`
- Modify: `LOGIC.md`
- Test: `ObserveTests/ObserveTests.swift`

**Interfaces:**
- Consumes: `InitialCameraTilePolicy` and `CameraFeedCoordinator.hasFreshImageThisSession`.

- [ ] **Step 1: Add failing presentation-policy assertions**

Assert that the launch-placeholder decision independently controls image suppression, forced red border, and status-row visibility without changing the ordinary classifier result.

- [ ] **Step 2: Run the test and verify RED**

Expect failure because the tile presentation decision does not exist.

- [ ] **Step 3: Implement the minimal tile branch**

When the launch placeholder is active, pass `nil` to `CameraSurfaceView`, show the existing icon placeholder, force the red border, and omit `statusLine`. Otherwise use the existing source, stale border, and status row unchanged.

- [ ] **Step 4: Update authoritative logic**

Document the initial-launch exception before the ordinary stale-marking logic: recent cached images display normally; stale or missing cached images use the silent red placeholder until current imagery arrives.

- [ ] **Step 5: Run focused tests and verify GREEN**

Confirm all new presentation cases pass.

### Task 4: Cross-Platform Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run the complete Mac Catalyst suite**

Run `xcodebuild test` for Mac Catalyst and require zero failures.

- [ ] **Step 2: Run the complete iPhone Simulator suite**

Run `xcodebuild test` on the available iPhone 17 Pro simulator and require zero failures.

- [ ] **Step 3: Run a signed generic iOS build**

Run `xcodebuild build -destination 'generic/platform=iOS'` and require `BUILD SUCCEEDED`.

- [ ] **Step 4: Validate the diff**

Run `git diff --check`, inspect the scoped diff, and confirm no unrelated loading, stale, reconnect, scheduling, or detail-view behavior changed.
