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
|   +-- Every rebuilt wall session receives a new generation. Snapshot, live,
|       constrained, and availability callbacks from an older generation must
|       be ignored and must not mutate the active session.
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
|       battery camera visibility toggle is shown and off.
|   +-- If the battery camera visibility toggle button setting is off, force
|       the user-level battery camera visibility state on so battery cameras
|       remain visible and reachable while the control is hidden.
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
+-- Start universal STARTUP COVERAGE PHASE
    |
    +-- Optimize for the first trusted image on every visible camera before
    |   ordinary live-wall assignment, regardless of whether restricted mode
    |   has already been detected.
    +-- Immediately queue untrusted non-battery snapshot work in UI priority
    |   order. Defer routine refreshes for already-trusted cameras until startup
    |   coverage ends.
    +-- Run at most 2 active snapshot requests until the first non-battery
    |   camera becomes trusted, then at most 3 active requests. Snapshot
    |   concurrency is an internal scheduling policy, not a user setting.
    +-- Keep at most 4 HomeKit snapshot requests outstanding, including overdue
    |   requests whose callbacks have not returned.
    +-- A request that has not returned after 4 seconds becomes overdue:
    |   |
    |   +-- It stops consuming an active scheduler slot.
    |   +-- It continues consuming an outstanding-request slot.
    |   +-- Keep its HomeKit request identity and per-camera ownership.
    |   +-- Do not issue another request for that camera until its callback returns.
    +-- In parallel, allow exactly one battery trusted-still live capture.
    |   Focused viewing wins that live opportunity.
    |   A battery live-start alone does not resolve startup coverage; the
    |   Observe-captured trusted still must complete first.
    +-- Use that battery stream as the initial live transport probe. If no
    |   battery camera needs capture, immediately start one UI-priority wired
    |   live probe alongside the capped snapshot lane.
    +-- If the initial probe becomes live within 3 seconds of session start,
    |   classify this launch as fast local transport and immediately request
    |   live video for every visible camera. Continue trusted-image accounting
    |   and battery trusted-still capture in the background.
    +-- A live start at or after 3 seconds does not activate the local fast path;
    |   retain the remote-safe serialized startup behavior.
    +-- Any constrained signal overrides the local fast-path classification and
    |   enters Restricted Mode using only streams that survived the rejection.
    +-- Do not start ordinary non-battery live streams until every visible
    |   non-battery camera has had its startup snapshot path attempted and no
    |   non-overdue snapshot request remains active.
    +-- Then allow one non-battery live fallback at a time, preserving that
    |   fallback until it becomes trusted or explicitly fails / times out.
    +-- Resolve each visible camera as either trusted or explicitly unresolved.
    |   Do not silently substitute an old image for a failed startup path.
    +-- One per-camera startup state machine owns snapshot-path state,
    |   live-path state, and final coverage resolution. Request, success,
    |   failure, timeout, trusted-image, and reset events must transition through
    |   that state machine; do not maintain parallel startup booleans.
    +-- A wired camera becomes unresolved only after both its snapshot and live
    |   paths fail. A battery camera becomes unresolved after its live capture
    |   path fails, because battery cameras do not use HomeKit snapshot requests.
    +-- A valid late success may move an unresolved camera to trusted.
    +-- End startup coverage only after every visible camera is resolved.
    +-- Continue ordinary background recovery for unresolved cameras afterward.
    |
    +-- After startup coverage, probe normal live capacity deterministically
        |
        +-- Preserve every visible stream that is already working, including a
        |   battery stream used for startup trusted-still capture.
        +-- Admit exactly one additional live stream in UI priority
        |   order and wait for it to report active before admitting another.
        +-- Defer routine snapshot refreshes for startup-trusted cameras until
        |   this capacity ramp succeeds or HomeKit reports a constrained signal.
        +-- If every admitted stream succeeds, keep every visible camera live.
        |   A battery camera performs any due trusted-still capture within that
        |   normal live stream and remains live afterward.
        +-- If HomeKit reports constrained live connections, enter RESTRICTED MODE.
        +-- If HomeKit reports `operationCancelled` after Observe intentionally
        |   stopped a stream, treat it as the expected stop callback rather than
        |   a camera failure or user-visible camera error.
        +-- If no live stream has successfully reported active yet, keep one
        |   restricted live slot available for battery capture or live fallback.
        +-- Learn restricted live capacity only from streams that actually survive
            the rejected request. Current failure evidence overrides any older
            remembered capacity; retry one extra slot only after the probe cooldown.

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
|   |   +-- After startup coverage, request the next snapshot as soon as the
|   |       previous request succeeds or fails, the per-camera minimum refresh interval
|   |       has elapsed, and a snapshot request slot is available.
|   |       Use a 2-second minimum while the camera still lacks a
|   |       trusted image; use the normal 5-second minimum after a recent
|   |       trusted image exists.
|   |       After a failed snapshot request, measure that minimum interval
|   |       from callback completion so retry waves do not immediately stampede
|   |       HomeKit again. An overdue request is not a completed failure and
|   |       must not be retried while HomeKit still owns it.
|   |   +-- Empty / stale cameras are more urgent than already-recent cameras.
|   |   +-- Preserve UI priority order within each snapshot urgency tier.
|   |   +-- A recent snapshot is trusted for display and stale marking.
|   |   +-- A trusted snapshot does not stop ongoing non-battery refresh work.
|   |   +-- If an overdue snapshot later succeeds before the camera has any
|   |       trusted image, accept it as the first trusted frame
|   |       as long as the returned capture age is within the configured stale
|   |       threshold. Old failures and late successes older than that threshold
|   |       must still be ignored.
|   |   +-- Snapshot refreshes do not consume restricted live slots.
|   |   +-- Snapshot refreshes may run in parallel with battery wake work.
|   |   +-- Never enqueue snapshot work with priority `none`, and never enqueue
|   |       HomeKit snapshot work for a configured battery camera.
|   |   +-- Snapshot request concurrency is controlled internally by Observe.
|   |       Do not expose a user setting or honor a persisted override.
|   |   +-- During startup coverage, adapt the active snapshot cap to observed
|   |       first-image progress:
|   |       |
|   |       +-- Before any non-battery camera has a trusted image, allow up
|   |           to 2 simultaneous snapshot requests.
|   |       +-- After at least one non-battery camera has a trusted image,
|   |           allow up to 3 simultaneous snapshot requests.
|   |       +-- Apply this cap from the first startup snapshot until every
|   |           visible camera is trusted or explicitly unresolved, then use
|   |           the internal steady-state limit of 3 active requests.
|   |       +-- Independently cap outstanding startup requests at 4. Overdue
|   |           requests count toward this cap even though they no longer consume
|   |           an active slot.
|   |       +-- After startup, cap outstanding requests at the same internal
|   |           steady-state limit of 3.
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
            +-- 3. During universal startup coverage
            |   |
            |   +-- Preserve a focused feed first.
            |   +-- Otherwise preserve or start one battery trusted-still capture.
            |   +-- If no battery capture is needed, allow one UI-priority wired
            |       live transport probe while startup snapshots are active.
            |   +-- Leave all other live slots idle while any non-overdue startup
            |       snapshot request is active unless the local fast path activates.
            |   +-- After every non-battery snapshot path has been attempted and
            |       no non-overdue snapshot request remains active, start one
            |       non-battery live fallback in UI priority order.
            |   +-- Do not rotate or duplicate that fallback while it is starting.
            |   +-- Mark the camera trusted when the live stream starts. Mark it
            |       explicitly unresolved if the one fallback fails or times out.
            |   +-- An explicit unresolved result ends that camera's blocking
            |       startup state without hiding the failure; background recovery
            |       resumes after startup coverage ends.
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
                |       number of streams that actually survived the rejected
                |       request and pause before retrying.
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
