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
                |   simultaneous live streams that have actually succeeded.
                +-- Remember confirmed restricted capacity by selected home and visible
                |   camera count.
                +-- On a later launch, if restricted mode is entered for that same
                |   wall context, start from the remembered capacity instead of one.
                +-- If HomeKit rejects that remembered capacity, drop back to the
                    currently observed live count and continue normally.

---

## Restricted Mode

RESTRICTED MODE
|
+-- Primary goal
|   |
|   +-- Make sure every visible camera has a recent / trusted image as quickly as possible.
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
|   |       succeeds, fails, the per-camera 5-second minimum refresh
|   |       interval has elapsed, and backoff allows.
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
    |       +-- Mark due battery cameras as "Queued".
    |       +-- Do not start any live feeds.
    |
    +-- Is at least one live slot available?
        |
        +-- Yes
            |
            +-- 1. Reserve the first live slot for the focused
            |      full-screen feed, if any
            |   |
            |   +-- Focus is an explicit cancellation reason for another
            |       active battery trusted-still capture if capacity is full.
            |   +-- If the focused camera is battery-powered, this live slot may
            |       also satisfy its battery wake / trusted still requirement.
            |
            +-- 2. Preserve active battery trusted-still captures
            |   |
            |   +-- Any battery camera already using a live slot to capture
            |       a trusted still keeps that slot unless focus explicitly
            |       needs the slot.
            |   +-- Do not swap, rotate, reprioritize, or reclaim that slot
            |       while the trusted still is still pending.
            |   +-- Release the slot only after success, timeout, or explicit
            |       focus cancellation.
            |   +-- A battery camera that is already warm live can become trusted
            |       as soon as the trusted-still warmup after live start is satisfied.
            |   +-- While HomeKit is still trying to establish live, use a separate
            |       live-start timeout so slow connection setup does not rotate the
            |       protected slot on the shorter capture warmup clock.
            |
            +-- 3. While any visible battery camera lacks a trusted still
            |   |
            |   +-- Use unleased remaining live slots for battery wake candidates.
            |   +-- Choose battery wake candidates in UI sort order.
            |   +-- Rotate to the next waiting candidate as slots become available.
            |   +-- If battery wake work does not consume all known live capacity,
            |       fill the remaining slots with the normal UI-priority live feeds.
            |   +-- If known restricted capacity may be too low and capacity probing
            |       is not blocked, cautiously try one additional live slot for
            |       eligible battery wake work.
            |   +-- Mark cameras waiting for a slot as "Queued"
            |       with a yellow indicator.
            |   +-- When a leased battery camera captures a still after the
            |       configured warmup time has elapsed since the stream became live:
            |       |
            |       +-- Mark it trusted.
            |       +-- Release / rotate the slot to the next waiting battery camera.
            |   +-- When a leased battery camera times out without a trusted still:
            |       |
            |       +-- If the stream became live, measure the capture timeout from
            |           live start so "Wait Before Capturing" means seconds live.
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

- A battery camera that owns a live slot for trusted-still capture shows
  "Live Capture".
- Once that capture stream is live, keep showing "Live Capture", switch the
  indicator to green, and append the remaining warmup countdown, for example
  "Live Capture (5s)".
- A battery camera that still needs a trusted still but does not currently own
  a live capture slot shows "Queued" with a yellow indicator.
- Show the stale red border only when the displayed still has actually reached
  the configured "Show As Stale" age, or when no still is available.

FOR EACH VISIBLE CAMERA
|
+-- Is this a battery camera currently capturing or queued for live capture?
    |
    +-- Yes
    |   |
    |   +-- Is the live capture stream currently live?
    |       |
    |       +-- Yes
    |       |   |
    |       |   +-- Not stale.
    |       |   +-- Status: Live Capture with warmup countdown.
    |       |   +-- Indicator: Green.
    |       |   +-- Border: None.
    |       |
    |       +-- No
    |           |
    |           +-- Does it have a displayed still within the configured
    |               "Show As Stale" threshold?
    |               |
    |               +-- Yes
    |               |   |
    |               |   +-- Not stale.
    |               |   +-- Status: Live Capture or Queued.
    |               |   +-- Indicator: Yellow.
    |               |   +-- Border: None.
    |               |
    |               +-- No
    |                   |
    |                   +-- Stale.
    |                   +-- Status: Live Capture or Queued.
    |                   +-- Indicator: Yellow.
    |                   +-- Border: Stale.
    |
    +-- No
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
