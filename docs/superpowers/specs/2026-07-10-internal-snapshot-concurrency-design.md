# Internal Snapshot Concurrency Design

## Goal

Remove Snapshot Requests from user settings and make snapshot concurrency an internal, deterministic scheduling policy.

## Decision

Observe owns snapshot concurrency. The scheduler allows two active requests before any non-battery camera produces a trusted startup image, then allows three active requests. Three remains the steady-state active and outstanding request ceiling after startup. During startup, the existing separate outstanding-request ceiling of four remains in force so overdue callbacks retain ownership without blocking all forward progress.

The old `observe.maxConcurrentSnapshotRequests` value is neither read nor used as a hidden override. Existing stored values may remain harmlessly in UserDefaults; no migration or prompt is needed.

## Alternatives Rejected

- Hiding the UI while continuing to honor the persisted value would preserve unpredictable behavior and make telemetry misleading.
- Adding a more elaborate feedback controller based on individual failures would add state and oscillation risk without evidence that the existing two-to-three ramp is insufficient.

## User Interface

Remove the Snapshot Refresh section and the Snapshot Requests number editor case. No replacement control or explanatory row is added.

## Telemetry

Report the internal maximum and the currently effective maximum. Rename the configured-looking telemetry field to `internalMaxConcurrentSnapshotRequests` so traces cannot imply user control.

## Verification

Tests must prove the internal policy ignores configuration because no configuration input exists, preferences no longer persist the old key, settings no longer expose the number-setting case, and telemetry reports the internal limit. Run the complete Mac Catalyst test suite and generic iOS Simulator and device builds.
