# Initial Camera Tile Placeholder Design

## Goal

During a new app session, prevent a stale or missing cached camera image from appearing as though it were the current camera view. Show the existing camera-icon placeholder with a red border and no status line until a usable current image arrives. A cached snapshot that already qualifies as recent under the camera's existing stale threshold remains eligible for immediate display.

## Scope

This behavior applies only to camera tiles on the camera wall during the initial image-acquisition period of a newly created or reset camera session. Camera detail presentation and every post-acquisition loading, stale, reconnect, battery-capture, queued, live, and error state remain unchanged.

## State and Policy

Each camera coordinator tracks whether it has received a fresh image during the current session. Session creation and reset begin with that flag false. Loading HomeKit's `mostRecentSnapshot` does not mark the session fresh. A successful new snapshot callback or a current live stream does.

A pure tile policy decides whether to use the launch placeholder. It returns true only when all of the following are true:

- The camera has not received a fresh image in this session.
- There is no displayed cached snapshot whose age is within the camera's existing visual stale threshold.

Thus a recent cached snapshot displays immediately with the existing status logic. A stale cached snapshot is deliberately hidden until a fresh image arrives. A missing image also uses the launch placeholder. A HomeKit transport state alone does not count as fresh unless a usable live camera source has actually been received.

## Presentation

While the launch-placeholder policy is active, the tile:

- Passes no camera source to the camera surface, hiding any stale cached image.
- Shows the existing black placeholder with the `video.fill` icon.
- Draws the existing red stale border.
- Hides the entire status row, including the dot, label, and elapsed-time suffix.
- Preserves the camera name and optional battery-percentage overlay.

When the policy becomes inactive, the tile immediately resumes the existing display classifier, image, status, border, and timing behavior without introducing a fallback or changing camera scheduling.

## Verification

Policy tests cover missing, stale cached, recent cached, fresh-session, and live inputs. Coordinator behavior is verified through existing snapshot/live tests where practical. The complete Mac Catalyst and iPhone Simulator suites must pass, followed by a signed generic iOS build and `git diff --check`.
