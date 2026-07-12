# Wi-Fi Live Burst Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a permission-free Wi-Fi-only all-live startup burst with bounded snapshot delay and deterministic fallback.

**Architecture:** A Network-framework classifier feeds a pure burst state machine. The camera store selects all visible live feeds only while the burst is open, releases snapshots after 200 ms, and closes permanently on capacity rejection or a two-second deadline.

**Tech Stack:** Swift, Network.framework, HomeKit, XCTest, Xcode

## Global Constraints

- Wi-Fi classification uses interface type only; no SSID, location, or Access Wi-Fi Information entitlement.
- Cellular and uncertain paths preserve the existing startup behavior.
- Snapshot head start delay is 200 ms and burst deadline is 2 seconds.
- One burst live attempt per camera; no speculative retry loop.
- First classified capacity rejection enters existing Restricted Mode.
- Late callbacks cannot reopen a closed burst.

---

### Task 1: Burst State Machine

**Files:** Modify `Observe/CameraRecoveryPlanner.swift`; test `ObserveTests/ObserveTests.swift`.

- [ ] Add failing tests for Wi-Fi opening, 200 ms snapshot release, the two-second wired deadline, bounded battery grace, success completion, and permanent capacity closure.
- [ ] Run focused Catalyst tests and verify RED.
- [ ] Implement `WiFiLiveBurstState` and verify GREEN.

### Task 2: Network Interface Classifier

**Files:** Create `Observe/CameraNetworkPathMonitor.swift`; test `ObserveTests/ObserveTests.swift`; modify Xcode project only if required by file membership.

- [ ] Add failing tests for Wi-Fi eligibility and conservative cellular/unknown behavior using injected path classifications.
- [ ] Implement the permission-free `NWPathMonitor` adapter and verify focused tests.

### Task 3: Store Integration and Telemetry

**Files:** Modify `Observe/HomeKitCameraStore.swift`, `Observe/CameraModels.swift`, `LOGIC.md`, and tests.

- [ ] Add failing policy tests proving Wi-Fi uses all live IDs while snapshots are held, and non-Wi-Fi retains first-image policy.
- [ ] Integrate one burst per session, snapshot admission gating, capacity circuit breaker, deadline closure, reset behavior, and telemetry.
- [ ] Update `LOGIC.md` and verify focused tests.

### Task 4: Verification

- [ ] Run full Mac Catalyst tests.
- [ ] Run full iPhone Simulator tests.
- [ ] Run a signed generic iOS build.
- [ ] Run `git diff --check` and audit the scoped diff.
