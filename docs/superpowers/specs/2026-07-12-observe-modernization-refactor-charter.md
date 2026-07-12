# Observe Modernization Refactor Charter

## Goal

Modernize Observe's source organization without changing camera behavior, UI behavior, persisted settings, HomeKit handling, or telemetry output.

`LOGIC.md` remains the authoritative behavior contract. A refactor pass must stop if it cannot preserve that contract. Behavior fixes and migrations are not part of this campaign.

## Locked Constraints

- Work directly on `main` in small reviewable commits.
- Keep Swift 5, XCTest, `ObservableObject`, `@Published`, `@StateObject`, and `@ObservedObject`.
- Add or upgrade no dependencies and change no deployment targets or build settings.
- Preserve the interfaces of `HomeKitCameraStore`, `CameraFeedCoordinator`, `CameraRecoveryPlanner`, `CameraWallView`, `SettingsView`, and `ObservePreferences` except for proven-unused internal inputs.
- Preserve preference keys, restricted-capacity evidence, telemetry keys and ordering, UI copy, gestures, accessibility labels, and platform presentation.
- Do not modify `LOGIC.md` unless an explicitly approved behavior change becomes necessary.

## Baseline

At the start of the refactor:

- The project has one shared `Observe` scheme and no package dependencies.
- `ObserveTests` contains 149 tests.
- All 149 tests pass on iPhone 17 with iOS 26.5.
- All 149 tests pass on Mac Catalyst.
- The compiler reports no source warning; Xcode only reports that App Intents metadata extraction is skipped because the app has no App Intents dependency.

## Behavior And Validation Map

| Contract area | Automated parity | Device parity |
| --- | --- | --- |
| Session generation and app activation | Session activation and generation tests | Background, foreground, and confirm stale callbacks do not alter the new session |
| Wall membership and camera availability | Availability, battery visibility, and preference tests | Disable and re-enable battery cameras; confirm active cameras retain stable wall identity |
| Startup coverage and snapshot scheduling | Startup state, snapshot admission, timeout, retry, and late-result tests | Launch once on home Wi-Fi and once on cellular; every visible camera becomes trusted or recovering |
| Wi-Fi live burst and remote-safe ramp | Wi-Fi burst, rescue, live-ramp, and admission tests | Confirm the Wi-Fi burst occurs once; confirm cellular skips it and uses bounded probing |
| Restricted capacity and recovery | Capacity, contention, fallback, and priority tests | Focus a camera under constrained capacity and confirm working streams are preserved |
| Battery trusted-still capture | Battery lease, timeout, warmup, trust, and backoff tests | Confirm due battery capture, warmup, trusted still, and slot release |
| Display, layout, and settings | Display classifier, wall layout, settings, and preference tests | Check wall, full-screen camera, settings sheet, numeric editor, names, and battery controls |
| Telemetry | Exact fixed-date report characterization plus milestone tests | Copy telemetry and compare fields, labels, ordering, and startup milestones |

## Source Ownership Target

- `HomeKitCameraStore` owns HomeKit discovery, session state, orchestration order, and application of planner decisions.
- Recovery planning and admission remain pure deterministic policy code outside the store.
- Telemetry models and report formatting live outside the store; the store remains the event source and keeps `telemetryReportText(at:)` as its entry point.
- `CameraFeedCoordinator` owns one HomeKit camera profile and its delegate callbacks; transport classification remains pure policy code.
- SwiftUI screen files own composition and local interaction state. Layout algorithms, window plumbing, and numeric setting controls live in focused files.
- Tests are grouped by the production behavior they protect and share only explicit fixture helpers.

## Per-Pass Gate

Every production pass must run its focused tests, the full iOS Simulator suite, the full Mac Catalyst suite, and `git diff --check`. Planner, coordinator, lifecycle, or store passes additionally require the relevant real-device checks above before final acceptance.
