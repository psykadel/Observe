# Live Transport State and Startup Timeout Design

## Goal

Prevent snapshot activity or one stalled wired camera from blocking first-image startup for the rest of the wall. Keep the repair small: make live-capacity ownership explicit, bound wired startup live attempts, and preserve the existing snapshot, battery, restricted-mode, and capacity-learning policies.

## Problem

`CameraFeedCoordinator` currently uses `FeedDisplayState.starting` both as a tile presentation state and as evidence that a HomeKit live transport is starting. Snapshot requests can set that display state, so a snapshot-only camera can be reported to `CameraLiveAdmissionController` as an active live transport and reserve capacity it does not own.

The coordinator also uses the battery-oriented 30-second live-start timeout for wired startup fallbacks. When that deadline is eventually reached, the current recovery path stops and immediately restarts the stream instead of waiting for HomeKit to confirm the stop. A genuinely stalled high-priority camera can therefore hold the serialized remote-start lane for too long and can re-enter it without yielding to pending cameras.

## Design Principles

- Presentation state is never scheduling authority.
- One local state describes the lifecycle of each commanded live transport.
- Observe never claims HomeKit capacity is free until a callback confirms the stop.
- A timed-out startup camera yields to cameras still awaiting their first image.
- Battery wake behavior keeps its longer deadline.
- Existing capacity-learning and snapshot scheduling policies remain unchanged.

## Authoritative Live Transport State

Replace the overlapping live lifecycle fields with one coordinator-owned state:

```swift
enum CameraLiveTransportState: Equatable {
    case idle
    case starting(requestedAt: Date)
    case streaming(startedAt: Date)
    case stopping(requestedAt: Date, reason: CameraLiveStopReason)
}

enum CameraLiveStopReason: Equatable {
    case planned
    case startupTimeout
}
```

The state is the sole local source for `LiveTransportPhase`, live-capacity reservation, start age, stop age, and whether a new start may be admitted. HomeKit stream state and callbacks remain external evidence used to reconcile the local lifecycle; `FeedDisplayState` remains presentation only.

The admission mapping is direct:

- `idle` -> no reservation
- `starting` -> reserves capacity
- `streaming` -> reserves capacity
- `stopping` -> reserves capacity until HomeKit confirms the stop

Snapshot requests may continue to display a loading presentation, but they never mutate `CameraLiveTransportState` and therefore never reserve live capacity.

## Live Transport Transitions

The normal transitions are:

```text
idle -> starting -> streaming -> stopping -> idle
                  \-> stopping -> idle
```

- A start command moves `idle` to `starting` before calling HomeKit.
- A start callback moves `starting` to `streaming`.
- A planner handoff moves `starting` or `streaming` to `stopping(reason: planned)` and calls `stopStream()` once.
- A wired startup deadline moves `starting` to `stopping(reason: startupTimeout)` and calls `stopStream()` once.
- A stop callback moves `stopping` to `idle` before the store replans.
- Observe never calls `startStream()` in the same transition that requests a stop.

If HomeKit reports a late start after Observe has entered `stopping`, the fresh live image may satisfy startup trust, but the transport remains `stopping`. The late callback cannot cancel the requested stop or promote the admission state back to `streaming`.

If a stop callback never arrives, the transport remains reserved. This is intentionally conservative: a timer may request a stop, but it cannot prove HomeKit released capacity.

## Startup Live Deadline

Add an explicit live-start timeout policy:

- Wired camera during startup coverage: 8 seconds.
- Battery camera: existing 30-second battery wake timeout.
- Ordinary live work after startup coverage: existing timeout behavior.

The shorter wired deadline applies only to first-image startup work. It does not change snapshot timeouts, battery wake behavior, focused-view priority, or steady-state capacity probing.

When a wired startup start reaches eight seconds:

1. Request a stop with reason `startupTimeout`.
2. Keep the capacity reservation while stopping.
3. On the stop callback, classify an expected cancellation or error-free stop as a startup timeout rather than an ordinary planner stop.
4. Apply the existing live-failure/backoff path and allow the startup camera state machine to enter recovery when its snapshot path has also failed.
5. Replan so a camera still awaiting its first-pass result outranks the timed-out recovering camera.

Real HomeKit errors retain their existing classification. For example, a busy, hard-capacity, infrastructure, or communication error returned with the callback is still handled by the corresponding existing policy rather than being hidden by the local timeout reason.

## Store and Admission Flow

`HomeKitCameraStore` continues to decide desired feeds and priority. `CameraLiveAdmissionController` continues to serialize starts, stops, handoffs, and learned capacity. The only change at their boundary is that transport phases now come exclusively from `CameraLiveTransportState`.

The store passes a per-request timeout selected by a small policy based on whether startup coverage is active and whether the feed is a battery camera. A timeout requests a stop; it does not directly admit a replacement. The replacement becomes eligible after HomeKit confirms the stop and the admission controller sees the transport return to `idle`.

No changes are made to:

- snapshot active or outstanding limits;
- overdue snapshot ownership;
- startup snapshot priority;
- battery trusted-still capture rules;
- soft-contention or hard-capacity learning;
- persisted topology capacity;
- focused camera priority;
- wall membership.

## Telemetry

Expose enough state to prove the boundary in future traces:

- authoritative live transport phase;
- live start age when starting;
- live stop age and stop reason when stopping;
- the wired startup live deadline.

Keep snapshot work state separate in the report. A valid report may therefore show a tile/display state of `starting` and snapshot work `active` while live transport phase is `idle`. That combination is expected and must not reserve live capacity.

Record a distinct startup live timeout event and include the camera ID and elapsed attempt time.

## Tests

Add focused deterministic tests for:

1. A snapshot request or loading display state leaves live transport `idle`.
2. Only `starting`, `streaming`, and `stopping` reserve live capacity.
3. A wired startup start times out at eight seconds; battery and ordinary starts retain their existing deadline.
4. Timeout requests one stop and never immediately restarts.
5. A replacement remains queued until the stop callback releases capacity.
6. After release, the next first-pass camera is admitted before the timed-out recovering camera.
7. A late start callback while stopping may provide trust but cannot restore streaming ownership.
8. Planned stops remain expected cancellations, while timeout stops follow the startup-failure/backoff path.
9. Real soft-contention, hard-capacity, infrastructure, and transport errors keep their current classifications.
10. Telemetry reports snapshot work and live transport phase independently.

Run the focused startup, admission, transport, scheduling, and telemetry tests first. Then run the full Mac Catalyst and iPhone Simulator suites, lint the Xcode project, and run `git diff --check`. Simulator tests validate deterministic policy and integration behavior; final confidence about HomeKit callback timing still requires a real-device startup trace.

## Documentation

Update `LOGIC.md` in the implementation change to state that:

- presentation and snapshot state never reserve live capacity;
- wired first-image live starts have an eight-second deadline;
- timeout recovery requests a stop and waits for confirmation before replacement;
- the timed-out camera yields to pending first-pass cameras and recovers nonterminally.

## Out of Scope

- A general rewrite of snapshot or startup state machines.
- Increasing remote-safe live concurrency.
- Releasing a stopping transport on a timer without a HomeKit callback.
- Changing capacity persistence or probing.
- UI redesign or user-configurable timeout settings.
