# Capacity Probe and Telemetry Design

## Goal

Prevent optional live-capacity probes from overlapping snapshot work on the
same camera, preserve the cautious startup-ramp behavior while naming its
measurement accurately, and make the resulting telemetry describe historical
and current state without ambiguity.

## Capacity-Probe Admission

`LiveIntent` will carry whether its camera has an outstanding snapshot request.
`LiveAdmissionController` will exclude only capacity-probe intents whose own
snapshot request is still active or overdue. Existing live feeds and other
eligible probe candidates remain available. Observe will not cancel snapshots,
pause unrelated live work, or change the capacity-expansion cooldown.

The admission controller will expose the IDs deferred for snapshot work. The
existing bounded live-plan transition event and telemetry report will include
those IDs so a trace explains why a planned expansion did not start yet.

## Startup Live-Ramp Measurement

The existing three-second ramp classification remains based on elapsed time
since the Observe camera session began. That measurement intentionally reflects
overall startup health, not only a single HomeKit live callback. This preserves
the conservative result seen when snapshot recovery was slow even though the
first later live callback was quick.

Code and telemetry will use `sessionElapsed` and `fastSessionThreshold` names.
The classification event will state both values explicitly. No pending-start
limit or network behavior changes.

## Telemetry Clarity

- Report capacity probes deferred by outstanding snapshot work.
- Rename `recoveringFeedIDs` in report text to
  `firstPassRecoveryFeedIDs`; the stored milestone is historical.
- Report startup metadata admission as `complete` after its queue and active
  operation are empty following completed work.
- For a live battery camera, omit a misleading capture-due countdown and report
  its battery capture schedule as `coveredByLive`.
- Keep telemetry bounded and avoid repeated per-refresh diagnostic events.

## Validation

Use test-first development for probe admission and telemetry formatting. Run
focused policy and telemetry tests, then the full Mac Catalyst and iPhone
Simulator suites. Validate the Xcode project file and run `git diff --check`.
No commit will be created.

`LOGIC.md` remains unchanged because this design preserves its documented
startup, live-capacity, snapshot, and battery-camera behavior.
