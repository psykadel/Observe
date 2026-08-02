# How Observe Handles Cameras

This document explains what Observe should do from the user's point of view.

**Writing rule:** Keep it understandable to someone who uses Observe but does
not build it. Describe what the user sees and what the app does next. Use plain
language. Keep class names, internal labels, detailed timers, and retry formulas
in the code and tests.

## Which Cameras Appear

Observe remembers the user's home, camera order, live order, layout, and
settings. Each time a new camera view begins, it asks HomeKit for the current
cameras and starts fresh.

- Show every camera that HomeKit says is on and reachable.
- Do not remove a camera just because a picture or live-video request failed.
- Remove a camera only when HomeKit says it is off, disabled, or unreachable.
- Return a recovered camera to its saved place in the layout.
- Ignore late results left over from an earlier camera view.
- Do not restart everything when the already-open app receives another
  “active” notification.

When the user hides battery cameras, remove them from the layout and do not wake,
refresh, or connect to them. If the option to hide battery cameras is itself
hidden, keep battery cameras visible.

## What Counts as a Current Picture

For an ordinary camera, either live video or a recent snapshot is current.

For a battery camera, either live video or a recent still captured by Observe is
current. Battery cameras do not provide ordinary HomeKit snapshots. If a
battery camera is already live, Observe keeps it live without running a separate
live capture.

On the configured Home Network, live video is enough to show a battery camera
right away. It does not count as a saved battery still for later use.

Observe never presents an old picture as if it were current merely because a new
request failed.

## When the Camera View Opens

Observe starts each camera's useful work immediately. On the Home Network, every
camera goes straight to live with no snapshot request. In Restricted Mode, a
camera selected for live starts without waiting for a snapshot, and an ordinary
camera without a current picture also requests a snapshot. Battery cameras
outside the permanent live set briefly use the battery capture lane. Observe acts
on each useful result as soon as HomeKit returns it; one slow camera does not hold
back unrelated cameras.

If a Home Security indicator is enabled, it stays gray until every visible
camera has a current picture. Observe then reads the selected locks or
temperature sensors without controlling or changing anything in the home.

The Home Network setting starts blank. When the user enters a network name,
Observe compares it exactly with the name of the current Wi-Fi network. If the
names match, Observe starts every visible camera live immediately. It does not
apply Restricted Mode connection limits, Live Order, staged startup, or learned
capacity, and it does not request snapshots. A camera that fails keeps retrying
without changing the connection mode for the other cameras.

Observe asks for location access only when Settings opens because Apple requires
that permission to read the current Wi-Fi name. If the setting is blank, the
device is not on Wi-Fi, the network name is unavailable, or the names differ,
Observe uses Restricted Mode. When the network or setting changes, Observe makes
the decision again. On a Mac, Observe can still identify the associated Wi-Fi
network when another interface is the primary network route. It never includes
either network name in copied telemetry.

In Restricted Mode, Observe starts the permanent live set and needed picture
requests together. Every ordinary camera without a current picture requests a
snapshot immediately, including cameras in the live set. Battery cameras outside
the permanent set share one temporary live capture lane. A camera opened full
screen gets a permanent live position right away, even if its snapshot request is
still outstanding.

Observe registers availability and battery change notifications after the first
media admission pass. It postpones explicit availability and battery reads until
every visible camera has a current picture, then runs those background reads one
at a time with availability first.

A camera whose snapshot fails remains visible and retries immediately. Observe
keeps waiting for a slow request and does not issue a duplicate while that
request is unresolved. A useful picture is accepted as soon as HomeKit returns
it.

Observe still uses HomeKit's already-known availability values while building
the initial camera wall and subscribes to changes so a camera that turns on can
appear promptly. On the Home Network, availability notifications, availability
reads, and battery reads happen immediately. Deferred reads and the one-at-a-time
background rule apply only in Restricted Mode.

## Restricted Mode

Restricted Mode is used whenever Observe cannot confirm an exact match with the
configured Home Network. Observe directly assigns the available live positions
instead of waiting for a snapshot phase to finish.

### Ordinary Cameras

An ordinary camera outside the permanent live set requests a snapshot
immediately and keeps receiving periodic snapshots. An ordinary camera in the
live set also requests a snapshot when it has no current picture. Missing and old
pictures go first, followed by the user's camera order. Snapshot requests are
independent; there is no wall-wide concurrency limit. Each camera may have only
one unresolved request, so a slow response cannot cause duplicate requests to
that camera. A late picture is useful only if it is still recent and no newer
picture has already arrived.

Snapshot retrying is driven only by HomeKit results. A successful request
returns to the normal refresh cadence. A failed request is retried immediately
if the camera still needs a picture. A request that has not returned simply
remains the camera's one outstanding request.

Snapshot requests never delay live starts, and live starts never cancel snapshot
requests that HomeKit is already handling. If the snapshot arrives first,
Observe shows it immediately while live continues connecting. When actual live
video arrives, it replaces the snapshot. A snapshot that returns after video is
live is saved but does not replace the video.

Snapshots do not use one of HomeKit's limited live connections.

### Battery Cameras

A battery camera selected for the permanent live set starts live immediately and
does not capture a saved still. Live video itself is its current picture.

A battery camera outside the permanent set that needs a new still briefly uses
the single battery capture lane: start live, wait for actual video, finish the
configured warmup, save one still, and stop. Actual video counts as current as
soon as it appears; the saved still is needed only so the camera can leave the
temporary lane and remain current afterward.

- Let an active capture finish instead of continually rotating cameras.
- Count the capture wait from when live video actually begins, not while the
  camera is still waking.
- The full-screen camera takes a permanent position instead of the temporary
  capture lane.
- After a failure or timeout, stop the connection cleanly, wait before trying
  that camera again, and give the next battery camera a turn.
- Show **Queued** while a battery camera is waiting for a connection.

### Who Gets Live Video First

Choose the permanent live set in this order:

1. The camera the user opened full screen.
2. The remaining cameras in Live Order.

If a battery camera outside that set needs a still, reserve exactly one of the
available positions as the temporary battery capture lane. The other positions
remain permanent. Let the active capture finish, then rotate the lane to the
next eligible battery camera. When the queue is empty, restore the displaced
permanent camera. With three battery cameras in Live Order and two available
positions, for example, the first remains permanently live while the capture
lane captures the third; the second then takes its permanent position, making
the final permanent set the first two cameras.

Observe remembers a confirmed live-camera limit for each home and exact group of
visible cameras. A different group starts fresh. When that exact limit is known,
Observe starts all assigned positions together. When it is unknown, Observe
starts one camera; each confirmed video opens exactly one more start until every
camera is live or HomeKit clearly refuses the next position.

A clear capacity refusal lowers and remembers the number of feeds that continued
working. A temporary busy message, camera-specific failure, network problem, or
Home Hub problem does not lower the remembered limit. Once an exact limit is
known, Observe uses it without periodically testing an additional position.

## Starting and Stopping Live Video

Observe must stop a feed it no longer needs before using that connection for a
replacement. A connection remains occupied while it is starting, playing, or
stopping.

HomeKit saying “started” is not enough to show **Live**. Observe must have actual
video to display. Until then, keep showing the previous picture or loading view.

While video is live or still stopping, a newly returned snapshot must not replace
it. Once HomeKit confirms that video stopped, show the available snapshot right
away.

When something goes wrong:

- If HomeKit clearly says no more live feeds are allowed, remember only the
  number that continued working.
- If HomeKit says it is busy, slow down temporarily and try one more feed later.
- If the network or Home Hub is unavailable, wait and retry without marking the
  cameras bad or changing the remembered limit.
- If only one camera fails, wait before retrying that camera and let the others
  continue.
- A cancellation caused by Observe intentionally stopping a feed is normal, not
  an error.

## What the User Sees

When Success Indicator is on, Observe briefly draws a green glow around the
camera wall once each time the app is opened or returned to and every visible
camera has a current picture and every enabled Home Security indicator is
green. Disabled Home Security indicators do not count. Turning the indicator
on while the wall is already healthy can show it for the current open. It does
not repeat until Observe is left and opened again, even if a status changes and
recovers.

When **Only Off Home Network** is also on, the glow appears only after Observe
can confirm that the device is away from the configured Home Network. It does
not appear while that network matches, while no Home Network is configured, or
while the current Wi-Fi name is unavailable.

During Restricted Mode startup, when no camera has a current picture yet,
Observe shows a centered loading panel. It confirms **Home Found**, reports the
Home Hub as connected, disconnected, or not available, and shows **Contacting N
Cameras** beside a spinner.

The panel appears only if startup lasts long enough to be noticeable and stays
visible while recovery continues. It disappears immediately when any camera
has a current still picture or actual video to display. The panel does not
distinguish camera types, and the controls above it remain available.

At first, show a saved picture only when it is still recent. Otherwise show the
black camera placeholder, camera name, optional battery percentage, and red
border. Hide the status row until a new picture or live video arrives.

After that:

| What is visible | Status | Color | Border |
| --- | --- | --- | --- |
| Live video | Live | Green | None |
| A recent still picture | Recent | Yellow | None |
| No picture, or an old picture | Stale | Red | Red |

A battery camera actively capturing shows **Live Capture**. Once live, it is
green and shows the remaining warmup time. While connecting, it is yellow. A
battery camera waiting its turn shows **Queued** in yellow.

For a connecting or queued battery camera, the red border describes only the
picture currently on screen: show it when that picture is old or missing.

Use the battery stale setting for battery-camera stills and the standard stale
setting for all other cameras. Marking a picture stale changes only its display;
it does not itself start a refresh or use a live connection.
