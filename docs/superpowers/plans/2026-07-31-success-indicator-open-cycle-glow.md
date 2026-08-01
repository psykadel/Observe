# Success Indicator Open-Cycle Glow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play Success Indicator once per foreground open and deliver a flowing, radiant, sparkling perimeter animation on iPhone and Mac Catalyst.

**Architecture:** Keep combined health in `HomeKitCameraStore`, replace the process-lifetime latch with a pure open-cycle state policy, and drive a self-contained SwiftUI glow from a pure elapsed-time timeline model. `CameraWallView` owns lifecycle wiring while the renderer owns only drawing.

**Tech Stack:** Swift, SwiftUI, XCTest, HomeKit, Xcode Mac Catalyst and iPhone Simulator targets.

## Global Constraints

- Work directly on `main` and leave all changes uncommitted.
- Add no dependency, coordinator, production trigger, sound, or haptic.
- Keep the effect on the main camera wall outer rim and away from Settings and camera detail.
- Preserve the existing combined-health definition and keep `LOGIC.md` customer-facing and authoritative.

---

### Task 1: Open-Cycle Trigger Policy

**Files:**
- Modify: `Observe/CameraPresentationPolicies.swift`
- Modify: `ObserveTests/ObservePreferencesTests.swift`

**Interfaces:**
- Produces: `SuccessIndicatorOpenState.beginOpen()`
- Produces: `SuccessIndicatorOpenState.shouldAnimate(isEnabled:isHealthy:) -> Bool`

- [ ] **Step 1: Write failing tests** proving an animation can occur once in
  each open cycle, enabling while already healthy can use the current cycle,
  remaining healthy cannot replay, and unhealthy recovery cannot replay.
- [ ] **Step 2: Run the focused `ObservePreferencesTests` target** and verify
  the new tests fail because the existing process-session policy never resets
  and consumes success while disabled.
- [ ] **Step 3: Replace `SuccessIndicatorSessionState`** with the minimal
  `SuccessIndicatorOpenState` implementation required by the tests.
- [ ] **Step 4: Run the focused tests** and verify the open-cycle policy passes.

### Task 2: Deterministic Animation Timeline

**Files:**
- Modify: `Observe/CameraPresentationPolicies.swift`
- Modify: `ObserveTests/ObservePreferencesTests.swift`

**Interfaces:**
- Produces: `SuccessIndicatorAnimationTimeline.presentation(at:reduceMotion:)`
- Produces: a presentation value containing draw progress, core opacity,
  radiance, trail phase, sparkle intensity, and completion.

- [ ] **Step 1: Write failing timeline tests** with hand-derived expectations
  at zero, sweep completion, sparkle peak, fade, completion, and Reduce Motion.
- [ ] **Step 2: Run focused tests** and verify failure because the timeline API
  does not exist.
- [ ] **Step 3: Implement the minimal clamped timeline math** for a roughly
  3.2-second normal or Reduce Motion presentation.
- [ ] **Step 4: Run focused tests** and verify every timeline boundary passes.

### Task 3: Lifecycle Wiring and Energy Perimeter

**Files:**
- Modify: `Observe/CameraWallView.swift`

**Interfaces:**
- Consumes: `SuccessIndicatorOpenState`
- Consumes: `SuccessIndicatorAnimationTimeline`

- [ ] **Step 1: Wire initial appearance, scene activation, health changes, and
  preference changes** through one evaluation helper. Begin a new cycle before
  evaluating each foreground activation.
- [ ] **Step 2: Replace the sequential two-stroke renderer** with a stable
  `TimelineView`-driven root containing a radiant core, angular traveling
  current, chasing trails, and a small deterministic `Canvas` sparkle layer.
- [ ] **Step 3: Implement Reduce Motion** as full-border fade, gentle aura, and
  stationary twinkles with no perimeter travel.
- [ ] **Step 4: Expand the debug preview** with representative camera-wall
  tiles and both normal and Reduce Motion variants.
- [ ] **Step 5: Build the iPhone Simulator target** and resolve all compiler or
  runtime issues before moving on.

### Task 4: Customer Contract and Verification

**Files:**
- Modify: `LOGIC.md`

**Interfaces:**
- Consumes: the approved open-cycle behavior and unchanged health definition.

- [ ] **Step 1: Update `LOGIC.md`** to say the glow can appear once each time
  Observe is opened or returned to, including when enabled after health is
  already green during that open.
- [ ] **Step 2: Run focused policy/timeline tests.**
- [ ] **Step 3: Run the complete Mac Catalyst and iPhone Simulator suites.**
- [ ] **Step 4: Render and inspect the iPhone and Mac glow presentations,**
  including Reduce Motion, rim confinement, input transparency, and camera
  visibility.
- [ ] **Step 5: Run `plutil -lint Observe.xcodeproj/project.pbxproj`,
  `git diff --check`, and final diff review.**

