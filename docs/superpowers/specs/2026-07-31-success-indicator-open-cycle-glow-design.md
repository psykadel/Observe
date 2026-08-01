# Success Indicator Open-Cycle Glow Design

## Goal

Make Success Indicator play once each time Observe is opened or returns to the
foreground, and turn the current static-looking green trace into a polished,
energetic perimeter celebration that remains outside the camera content.

## Considered Directions

1. **Layered energy perimeter (selected).** Combine a traveling highlight,
   breathing aura, secondary light trails, and a small deterministic sparkle
   burst. This feels celebratory while keeping every effect attached to the
   outer rim.
2. **Enhanced neon trace.** Retain the existing two strokes and add stronger
   blur and a pulse. This is inexpensive but too close to the current result.
3. **Particle celebration.** Emit many particles around the whole screen. This
   is visually dramatic but risks covering cameras and feeling like a full
   screen takeover.

The selected direction provides the requested flow, radiation, and sparkle
without introducing a particle engine, dependency, sound, haptic, or overlay
over the camera tiles.

## Open-Cycle Behavior

- An open cycle starts on initial `CameraWallView` appearance and whenever the
  app enters the active scene phase again.
- Each open cycle has one animation opportunity.
- The opportunity is consumed only when the setting is enabled and the
  combined status is healthy.
- If the setting is enabled while the current open cycle is already healthy,
  the animation plays immediately.
- Remaining healthy, becoming unhealthy and recovering, or changing settings
  after the animation has played does not replay it during that open cycle.
- Leaving Observe and returning to it begins a new open cycle, even though the
  process was not force-quit.

The combined health definition does not change: at least one camera must be
visible; every visible camera must have a trusted still or actual live video;
and every enabled Home Security indicator must be green.

## Visual Design

The effect lasts about 3.2 seconds and is clipped to a narrow band along the
camera wall boundary:

1. A luminous green current sweeps around the rounded perimeter.
2. A full-rim core resolves behind it while a broader translucent aura expands
   and settles, producing a flow-in/flow-out impression without scaling over
   the cameras.
3. Two shorter highlight trails chase the leading current to give the rim
   depth and motion.
4. A small set of deterministic four-point sparkles blooms near the perimeter
   and disappears before the final fade.
5. The complete ring breathes once, then the core, aura, trails, and sparkles
   fade together.

The core remains approximately 5-7 points thick. Blur and shadow may radiate
outside that core, but visible particles remain in the outer rim band. The
overlay remains above the wall and below ordinary controls, ignores hit
testing, is hidden from accessibility, and never appears in Settings or camera
detail.

Under Reduce Motion, the entire ring fades in, gently radiates, shows a few
stationary twinkles, holds, and fades out. It omits the traveling sweep and
chasing trails.

## Structure

- `SuccessIndicatorOpenState` remains a small pure value policy in the existing
  presentation-policy module. It owns the one-animation-per-open rule.
- `CameraWallView` begins open cycles and reevaluates on health changes, setting
  changes, and scene activation.
- `SuccessIndicatorGlow` becomes a self-contained SwiftUI rendering component.
  A pure timeline model converts elapsed time and Reduce Motion into drawing
  progress, opacity, radiance, trail positions, and sparkle intensity so the
  timing is unit-testable.
- Native SwiftUI shapes, gradients, `Canvas`, and `TimelineView` provide the
  rendering. No external dependency or production trigger is added.

## Verification

- Policy tests cover initial open, repeated health, recovery, enabling while
  already healthy, and a new foreground open cycle.
- Timeline tests cover the start, sweep, pulse, sparkle, fade, completion, and
  Reduce Motion states using hand-derived expectations.
- Focused tests run red before production changes and green afterward.
- Full Mac Catalyst and iPhone Simulator suites, visual simulator/preview QA,
  project plist validation, and `git diff --check` finish the change.

