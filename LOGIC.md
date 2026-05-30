# Live / Refresh Logic

## App Start / Session Start

APP START / SESSION START
|
+-- Persist user settings only
|   |
|   +-- Keep user choices such as selected home, camera order, wall layout,
|       stale thresholds, and battery-camera settings across app opens.
|   +-- Do not persist the active operational camera session as authoritative.
|   +-- Rebuild the active wall from current HomeKit discovery and current
|       per-session camera availability each time a fresh wall session starts.
|
+-- Build active visible wall set
|   |
|   +-- Include every camera discovered for the selected home unless HomeKit
|       explicitly reports that camera as off or not responding.
|   +-- Cameras that are powered off, reported inactive by HomeKit's
|       HomeKitCameraActive state, or reported manually disabled by HomeKit's
|       camera operating mode state, must not occupy wall layout slots.
|   +-- Cameras whose HomeKit accessory is not reachable / not responding must
|       not occupy wall layout slots.
|   +-- Do not remove cameras from the wall for restricted-mode pressure,
|       transient stream failures, snapshot failures, network errors, or
|       HomeKit communication errors while the accessory is still reachable.
|       Those conditions may change status, live assignment, or refresh
|       behavior, but they must not consume the camera's wall identity or make
|       it disappear.
|   +-- If HomeKit later reports an off or not-responding camera as active and
|       reachable again, it may re-enter the wall according to the persisted
|       user priority order.
|
+-- Start in OPTIMISTIC MODE
    |
    +-- Are HomeKit live connections constrained?
        |
        +-- No
        |   |
        |   +-- Keep all visible cameras live.
        |   +-- While live streams are still starting, request fallback snapshots
        |       for non-battery cameras that are not yet live.
        |   +-- Prioritize empty / stale non-battery snapshots ahead of recent
        |       continuous refresh snapshots.
        |   +-- Snapshot fallback work does not consume live slots and must not
        |       block live startup.
        |
        +-- Yes
            |
            +-- Enter RESTRICTED MODE.
            |
            +-- If no live stream has successfully reported active yet:
            |   |
            |   +-- Do not treat failed startup attempts as proof that live capacity is 0.
            |   +-- Keep one restricted live slot available so battery capture can begin.
            |
            +-- The one-slot fallback is only an initial fallback.
                |
                +-- Restricted live capacity must be learned from the highest number of
                    simultaneous live streams that have actually succeeded in this session.

---

## Restricted Mode

RESTRICTED MODE
|
+-- Primary goal
|   |
|   +-- Make sure every visible camera has a recent / trusted image.
|
+-- Determine whether each visible camera has a trusted image
|   |
|   +-- Non-battery camera
|   |   |
|   |   +-- Is the camera currently live?
|   |       |
|   |       +-- Yes -> Trusted.
|   |       |
|   |       +-- No
|   |           |
|   |           +-- Does it have a recent snapshot?
|   |               |
|   |               +-- Yes -> Trusted.
|   |               +-- No  -> Needs snapshot refresh.
|   |
|   +-- Battery camera
|       |
|       +-- Does it have an Observe-captured still within the
|           "Start Live Capture After" threshold?
|           |
|           +-- Yes -> Trusted.
|           +-- No  -> Needs battery wake / live capture.
|
+-- Refresh work
|   |
|   +-- Non-battery cameras that are not live
|   |   |
|   |   +-- Refresh snapshots immediately and continuously.
|   |   +-- Request the next snapshot as soon as the previous request
|   |       succeeds, fails, or backoff allows.
|   |   +-- Empty / stale cameras are more urgent than already-recent cameras.
|   |   +-- Preserve UI priority order within each snapshot urgency tier.
|   |   +-- A recent snapshot is trusted for display and stale marking.
|   |   +-- A trusted snapshot does not stop ongoing non-battery refresh work.
|   |   +-- Snapshot refreshes do not consume restricted live slots.
|   |   +-- Snapshot refreshes may run in parallel with battery wake work.
|   |
|   +-- Battery cameras that do not have trusted stills
|       |
|       +-- Must receive a live slot long enough to wake.
|       +-- Must capture an Observe-captured still.
|       +-- Any warm live battery stream may produce the Observe-captured still,
|           whether it began during optimistic startup, focused live viewing,
|           or a restricted live wake lease.
|       +-- After the Observe-captured still is received, the camera becomes trusted.
|       +-- If a live wake lease times out without a trusted still:
|           |
|           +-- Release the live slot.
|           +-- Put that camera under a short retry backoff.
|           +-- Let the next eligible waiting battery camera try the slot.
|
+-- Build live-slot plan
    |
    +-- Is live capacity currently 0?
    |   |
    |   +-- Yes
    |       |
    |       +-- Refresh non-battery snapshots continuously.
    |       +-- Mark due battery cameras as "Wait for Capture".
    |       +-- Do not start any live feeds.
    |
    +-- Is at least one live slot available?
        |
        +-- Yes
            |
            +-- 1. Preserve active battery trusted-still captures
            |   |
            |   +-- Any battery camera already using a live slot to capture
            |       a trusted still keeps that slot.
            |   +-- Do not swap, rotate, reprioritize, or reclaim that slot
            |       while the trusted still is still pending.
            |   +-- Release the slot only after success or timeout.
            |   +-- A battery camera that is already warm live can become trusted
            |       as soon as the trusted-still warmup is satisfied.
            |
            +-- 2. Reserve the first unleased live slot for the focused
            |      full-screen feed, if any
            |   |
            |   +-- Focus wins among slots that are not already leased to an
            |       active battery trusted-still capture.
            |   +-- If the focused camera is battery-powered, this live slot may
            |       also satisfy its battery wake / trusted still requirement.
            |
            +-- 3. While any visible battery camera lacks a trusted still
            |   |
            |   +-- Use unleased remaining live slots for battery wake candidates.
            |   +-- Choose battery wake candidates in UI sort order.
            |   +-- Rotate to the next waiting candidate as slots become available.
            |   +-- If known restricted capacity may be too low and capacity probing
            |       is not blocked, cautiously try one additional live slot for
            |       eligible battery wake work.
            |   +-- Mark cameras waiting for a slot as "Wait for Capture"
            |       with a yellow indicator.
            |   +-- When a leased battery camera captures a still after lease start:
            |       |
            |       +-- Mark it trusted.
            |       +-- Release / rotate the slot to the next waiting battery camera.
            |   +-- When a leased battery camera times out without a trusted still:
            |       |
            |       +-- Release / rotate the slot to the next waiting battery camera.
            |       +-- Keep the failed camera waiting under retry backoff until eligible.
            |
            +-- 4. Once every visible camera has a trusted image
                |
                +-- Use live slots normally.
                |
                +-- Maximize the final live end state
                |   |
                |   +-- Keep the highest successful simultaneous live count as the
                |       known restricted live capacity.
                |   +-- If known capacity is below the visible camera count,
                |       cautiously try one additional live slot.
                |   +-- If the additional slot succeeds, raise known capacity and
                |       continue discovering capacity.
                |   +-- If HomeKit reports another constrained signal, keep the
                |       highest successful capacity and pause before retrying.
                |
                +-- Do not let the initial one-slot fallback become the final
                |   restricted capacity after trusted images are available.
                |
                +-- Assign live feeds by UI priority order
                    |
                    +-- Focused feed still wins the first slot, if present.
                    +-- Remaining slots go to the highest-priority visible cameras.
                    +-- Battery and non-battery cameras are treated the same here.
                    +-- Cameras without live slots remain on their trusted still image.

---

# Stale Marking Logic

Stale marking is separate from refresh work.

Stale marking only decides what the app should call the currently displayed image right now. Refresh logic may respond to that state later, but marking a camera stale does not itself request a snapshot or consume a live slot.

For ordinary live / recent / stale states, status and border must agree:

- Stale means stale status, red indicator, and stale border.
- Not stale means non-stale status and no stale border.

Battery capture and waiting states are the exception:

- Keep the useful "Capturing" or "Wait for Capture" status text.
- Keep the yellow indicator.
- Show the stale red border until the battery camera has a trusted Observe-captured still.

FOR EACH VISIBLE CAMERA
|
+-- Is the camera currently streaming live?
    |
    +-- Yes
    |   |
    |   +-- Not stale.
    |   +-- Status: Live.
    |   +-- Indicator: Green.
    |   +-- Border: None.
    |
    +-- No
        |
        +-- Is this a battery camera currently capturing or waiting for live?
            |
            +-- Yes
            |   |
            |   +-- Does it already have a trusted Observe-captured still within
            |       the "Start Live Capture After" threshold?
            |       |
            |       +-- Yes
            |       |   |
            |       |   +-- Not stale.
            |       |   +-- Status: Capturing or Wait for Capture.
            |       |   +-- Indicator: Yellow.
            |       |   +-- Border: None.
            |       |
            |       +-- No
            |           |
            |           +-- Stale.
            |           +-- Status: Capturing or Wait for Capture.
            |           +-- Indicator: Yellow.
            |           +-- Border: Stale.
            |
            +-- No
                |
                +-- Does the camera have a displayed still image?
                    |
                    +-- No
                    |   |
                    |   +-- Stale.
                    |   +-- Status: Stale.
                    |   +-- Indicator: Red.
                    |   +-- Border: Stale.
                    |
                    +-- Yes
                        |
                        +-- Select stale threshold
                        |   |
                        |   +-- Battery camera:
                        |   |   |
                        |   |   +-- Use Battery Cameras "Show As Stale" threshold.
                        |   |
                        |   +-- Non-battery camera:
                        |       |
                        |       +-- Use standard Stale Threshold.
                        |
                        +-- Is the displayed still age within the selected threshold?
                            |
                            +-- Yes
                            |   |
                            |   +-- Not stale.
                            |   +-- Status: Recent.
                            |   +-- Indicator: Yellow.
                            |   +-- Border: None.
                            |
                            +-- No
                                |
                                +-- Stale.
                                +-- Status: Stale.
                                +-- Indicator: Red.
                                +-- Border: Stale.
