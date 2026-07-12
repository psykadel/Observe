# Wi-Fi Live Burst Design

## Goal

Restore nearly simultaneous live startup on Wi-Fi without changing cellular or uncertain-network startup and without requiring Wi-Fi information, SSID, location, or local-network permissions.

## Behavior

At session start, Observe reads only the active interface class. A satisfied Wi-Fi path opens one speculative live burst for all visible cameras. Every camera, including a configured battery camera with a due trusted still, enters plain live mode during this burst; the burst does not create a battery capture lease. Cellular, wired, unknown, unsatisfied, constrained, or otherwise uncertain paths use the existing startup path unchanged.

The Wi-Fi burst gives live starts a 200 ms head start. Snapshot work may be queued immediately but is not issued during that head start. Afterward, the existing capped snapshot lane runs as insurance until cameras become live or trusted. At two seconds, every visible non-battery camera must be live. If that condition is met, any still-starting battery cameras keep their plain-live requests through the existing battery live-start timeout. A battery-only wall receives the same bounded grace.

The burst closes permanently for the session on the first of:

- A classified HomeKit capacity rejection.
- The two-second deadline while any non-battery camera is still pending.
- The battery live-start deadline while only battery cameras remain pending.
- App/session reset or network-path invalidation.

Closing the burst never retries speculative starts. Streams already live remain evidence for Restricted Mode. Pending live starts are stopped once, intentional stop callbacks remain classified as requested, and the existing constrained-mode planner takes over. Late callbacks may update a feed but cannot reopen the burst.

## Architecture

- `CameraNetworkPathClassifying` supplies a synchronous launch classification backed by `NWPathMonitor` and a conservative fallback.
- `WiFiLiveBurstState` is a pure state machine owning timing, closure reason, and whether live-all or snapshot admission is allowed.
- `HomeKitCameraStore` owns one burst instance per session and feeds its live selection into the existing recovery planner.
- Existing session generations continue rejecting callbacks from older sessions.
- Telemetry records network class, burst opening, snapshot release, closure reason, live survivor count, and completion.

## Safety

- No SSID or home-network inference.
- No burst on cellular or an uncertain path.
- One speculative live attempt per feed; no burst retries.
- First capacity error is a circuit breaker.
- Existing snapshot caps, request identity, overdue handling, Restricted Mode, battery trust, and user priority remain authoritative after fallback.
