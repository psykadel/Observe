# How Observe Handles Cameras

This document explains what Observe should do from the user's point of view.

**Writing rule:** Keep it understandable to someone who uses Observe but does
not build it. Describe what the user sees and what the app does next. Use plain
language. Keep class names, internal labels, detailed timers, and retry formulas
in the code and tests.

## Which Cameras Appear

Observe remembers the user's home, camera order, layout, and settings. Each time
a new camera view begins, it asks HomeKit for the current cameras and starts
fresh.

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

For a battery camera, Observe normally needs to capture its own recent still
from a live connection. Battery cameras do not provide ordinary HomeKit
snapshots. If a battery camera is already live, Observe uses that connection
instead of opening another one.

During the initial Wi-Fi attempt, live video is enough to show the battery camera
right away. It does not count as a saved battery still for later use.

Observe never presents an old picture as if it were current merely because a new
request failed.

## When the Camera View Opens

Observe first tries to get a current picture for every visible camera. Only then
does it concentrate on showing as many live feeds as HomeKit will allow.

On Wi-Fi, Observe makes one quick attempt to start every camera live. It also
begins taking snapshots shortly afterward so the view still fills in when Wi-Fi
is not actually connected to the home network.

If that all-live attempt succeeds, keep it. If a camera fails, the attempt takes
too long, the network changes, or the visible cameras change, stop using this
fast approach for the rest of that camera view. Late responses must not turn it
back on.

On cellular or any other connection, Observe starts more cautiously:

- Take a few ordinary-camera snapshots at a time.
- Wake one battery camera that needs a new still. If none does, try one ordinary
  camera live.
- If a camera stalls or fails, move on so it cannot hold up the entire view.
- Add more live feeds gradually as HomeKit accepts them.
- If HomeKit clearly refuses another live feed, keep the feeds that still work
  and switch to Restricted Mode.
- If HomeKit is merely busy, slow down and try again without treating that as a
  permanent limit.

A camera whose first attempts fail remains visible and keeps trying in the
background. The initial loading period ends when every camera either has a
current picture or has moved into background recovery. A later successful
picture or live connection immediately brings that camera up to date.

## Restricted Mode

Restricted Mode means HomeKit will not allow every visible camera to be live at
the same time. Observe uses the available live connections to get every camera
up to date before filling the final live view.

### Ordinary Cameras

An ordinary camera that is not live keeps receiving snapshots. Missing and old
pictures go first, followed by the user's camera order.

Observe limits how many snapshot requests it makes at once. If HomeKit is slow
to answer, Observe may continue with other cameras, but it does not send a
duplicate request to the same camera. A late picture is useful only if it is
still recent and no newer picture has already arrived.

Snapshots do not use one of HomeKit's limited live connections.

### Battery Cameras

A battery camera that needs a new still must briefly use a live connection to
wake and capture it.

- Let an active capture finish instead of continually rotating cameras.
- Count the capture wait from when live video actually begins, not while the
  camera is still waking.
- The full-screen camera may take the connection if none is free.
- After a failure or timeout, stop the connection cleanly, wait before trying
  that camera again, and give the next battery camera a turn.
- Show **Queued** while a battery camera is waiting for a connection.

### Who Gets Live Video First

When live connections are limited, use them in this order:

1. The camera the user opened full screen.
2. Battery cameras already capturing a still.
3. Cameras still needed to finish the initial view.
4. Other battery cameras waiting for a new still, in layout order.
5. Normal live feeds, in layout order.

Do not use a waiting battery camera as an ordinary live feed. First give every
visible battery camera a current still. After every camera has a current picture,
carefully try to add more live feeds one at a time.

Observe remembers a confirmed live-camera limit for each home and exact group of
visible cameras. A different group starts fresh. A temporary busy message or a
network problem must not permanently lower the remembered limit.

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
