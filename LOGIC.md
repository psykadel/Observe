# Live / Refresh Logic

## App Start / Session Start

APP START / SESSION START
|
+-- Persist user settings only
|   |
|   +-- Keep user choices such as selected home, camera order, wall layout,
|       stale thresholds, and battery-camera settings across app opens.
|   +-- Keep whether battery cameras are currently enabled across app opens.
|   +-- Do not persist the active operational camera session as authoritative.
|   +-- Rebuild the active wall from current HomeKit discovery and current
|       per-session camera availability each time a fresh wall session starts.
|   +-- A redundant scene-phase notification that says the already-active app
|       is active again must not rebuild the HomeKit session or stop streams
|       that just started.
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
|   +-- Battery cameras must not occupy wall layout slots while the user-level
|       battery camera visibility toggle is off.
|   +-- A battery camera hidden by the user-level toggle must not receive
|       snapshot requests, live feed requests, live captures, refreshes,
|       battery wake leases, or other camera work while hidden.
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
|   |       succeeds or fails, the per-camera minimum refresh interval
|   |       has elapsed, and a snapshot request slot is available.
|   |       Use a 2-second minimum while the camera still lacks a
|   |       trusted image; use the normal 5-second minimum after a recent
|   |       trusted image exists.
|   |   +-- Empty / stale cameras are more urgent than already-recent cameras.
|   |   +-- Preserve UI priority order within each snapshot urgency tier.
|   |   +-- A recent snapshot is trusted for display and stale marking.
|   |   +-- A trusted snapshot does not stop ongoing non-battery refresh work.
|   |   +-- If a timed-out / superseded snapshot later succeeds before the
|   |       camera has any trusted image, accept it as the first trusted frame
|   |       as long as the returned capture age is within the configured stale
|   |       threshold. Old failures and late successes older than that threshold
|   |       must still be ignored.
|   |   +-- Snapshot refreshes do not consume restricted live slots.
|   |   +-- Snapshot refreshes may run in parallel with battery wake work.
|   |   +-- The maximum number of simultaneous snapshot requests is a
|   |       user-controlled setting that defaults to 3.
|   |   +-- Restricted-mode startup has a short snapshot-priming exception:
|   |       |
|   |       +-- If a higher-priority non-battery camera still lacks a
|   |           trusted snapshot, pause new lower-priority battery wake
|   |           starts briefly so HomeKit / the home hub can service the
|   |           urgent still requests first.
|   |       +-- Keep already-active battery trusted-still leases alive.
|   |       +-- Keep the focused full-screen feed live, including a focused
|   |           battery capture.
|   |       +-- Leave otherwise spare live slots idle during this priming
|   |           window instead of backfilling them with normal live feeds.
|   |       +-- End the priming exception as soon as the higher-priority
|   |           non-battery cameras are trusted, or after the user-controlled
|   |           "Priming Window" expires.
|   |       +-- "Priming Window" defaults to 10 seconds.
|   |
|   +-- Battery cameras that do not have trusted stills
|       |
|       +-- Must receive a live slot long enough to wake.
|       +-- Must capture an Observe-captured still.
|       +-- In restricted mode, any warm live battery stream may produce the
|           Observe-captured still, whether it began during focused live viewing
|           or a restricted live wake lease.
|       +-- Outside restricted mode, a battery camera that already has an
|           active live feed does not start a separate live capture session;
|           the live feed is already sufficient.
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
            |   +-- Release the slot after the camera has any trusted battery
            |       still, timeout, or explicit focus cancellation.
            |   +-- A battery camera that is already warm live can become trusted
            |       as soon as the trusted-still warmup after live start is satisfied.
            |   +-- While HomeKit is still trying to establish live, use a separate
            |       live-start timeout so slow connection setup does not rotate the
            |       protected slot on the shorter capture warmup clock.
            |
            +-- 3. During the restricted-mode startup snapshot-priming
            |      exception
            |   |
            |   +-- If a higher-priority non-battery camera lacks a trusted
            |       snapshot, do not start new lower-priority battery wake
            |       leases yet.
            |   +-- Preserve the focused feed and already-active battery
            |       trusted-still captures.
            |   +-- Leave remaining live slots idle so urgent snapshot work has
            |       the best chance to complete quickly.
            |   +-- Mark waiting battery cameras as "Queued (Priming)" with
            |       a yellow indicator.
            |   +-- Exit this exception as soon as those higher-priority
            |       non-battery stills become trusted, or when the user-controlled
            |       "Priming Window" expires.
            |
            +-- 4. While any visible battery camera lacks a trusted still
            |   |
            |   +-- Use unleased remaining live slots for battery wake candidates.
            |   +-- Choose battery wake candidates in UI sort order.
            |   +-- Rotate to the next waiting candidate as slots become available.
            |   +-- If battery wake work does not consume all known live capacity,
            |       fill the remaining slots with the normal UI-priority live feeds.
            |   +-- Battery cameras that still lack a trusted still are not normal
            |       live-fill candidates while they are waiting or under retry backoff.
            |       They may hold a live slot only as the focused feed, an active
            |       trusted-still capture, or a newly eligible battery wake lease.
            |   +-- Do not probe extra live capacity while any visible battery camera
            |       still lacks a trusted still. Use the known restricted capacity for
            |       battery wake first, then fill any leftover known slots normally.
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
            |       +-- If HomeKit rejects the live start before the stream becomes live,
            |           treat it as a failed wake attempt, not as a lease to preserve.
            |       +-- Stop the timed-out HomeKit live attempt so the next retry
            |           starts from a clean live connection request.
            |       +-- Release / rotate the slot to the next waiting battery camera.
            |       +-- Keep the failed camera waiting under retry backoff until eligible.
            |
            +-- 5. Once every visible camera has a trusted image
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
- During the startup snapshot-priming exception, a battery camera held back
  from starting a new capture shows "Queued (Priming)" with a yellow indicator.
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
    |               |   +-- Status: Live Capture, Queued, or Queued (Priming).
    |               |   +-- Indicator: Yellow.
    |               |   +-- Border: None.
    |               |
    |               +-- No
    |                   |
    |                   +-- Stale.
    |                   +-- Status: Live Capture, Queued, or Queued (Priming).
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
