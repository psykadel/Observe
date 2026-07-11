# Startup Camera State Machine Design

## Goal

Make startup coverage deterministic by giving each visible camera one authoritative state machine and rejecting callbacks from retired HomeKit sessions.

## State Model

`StartupCameraState` owns the startup-only snapshot path, live path, and final coverage resolution. Each path is one of `notAttempted`, `inFlight(startedAt:)`, `succeeded`, or `failed`. The state machine accepts explicit events: snapshot requested/succeeded/failed, live requested/started/failed, trusted image observed, and reset.

The state machine enforces these invariants:

- Snapshot success or a trusted-image observation resolves any camera as trusted.
- A wired live start resolves the camera as trusted.
- A battery live start does not resolve coverage until Observe captures its trusted still.
- A wired camera becomes unresolved only after both snapshot and live paths fail.
- A battery camera becomes unresolved after its live path fails.
- A later valid success may move an unresolved camera to trusted, preserving accepted late snapshot behavior.
- Attempted state, active live-fallback time, and resolution are derived from this single value rather than stored as parallel booleans.

Snapshot scheduler ownership, last request time, and battery lease/backoff remain in `FeedScheduleState`; they are not startup coverage state and have different lifetimes.

## Session Generation

`HomeKitCameraStore` increments a monotonically increasing generation before every feed rebuild and when invalidating an inactive session. Every feed callback closure captures the generation that created it. Snapshot, live, constrained, and availability handlers ignore callbacks whose captured generation does not equal the active generation.

This guards against callbacks from coordinators stopped or replaced during home changes, app activation changes, and HomeKit service rebuilds. Existing snapshot request IDs continue to protect request ordering inside one active session.

## Integration

`FeedPlanningSnapshot` continues exposing planner-friendly derived properties so priority and live-slot behavior remain unchanged. `HomeKitCameraStore` sends events to the state machine at the existing request, callback, timeout, battery-capture, and trusted-image seams. Telemetry reports the state machine's resolution and path states.

## Validation

Pure tests cover every resolution rule, reset behavior, late success, and session-generation matching. Existing planner tests protect priority, LAN fast fan-out, Restricted Mode, and battery behavior. Full Mac Catalyst tests and generic iOS builds remain required.
