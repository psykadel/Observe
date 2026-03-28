# Observe

Observe is a fast, minimal iPhone app for viewing Apple Home security cameras.

The goal is simple: open the app and see your cameras as quickly as possible, with the cleanest possible layout.

## What It Does

- Shows cameras from your Apple Home setup in a simple wall view
- Prioritizes live video when HomeKit allows it
- Falls back to recent snapshots when live video is limited
- Keeps the interface focused on the camera image, camera name, and current status
- Hides offline cameras from the main wall until they come back online

## How It Chooses What To Show

Observe follows a simple set of rules:

- It always tries to show live video first.
- Cameras are prioritized in the order you set in the app.
- If you open one camera full screen, that camera gets top priority.
- When HomeKit cannot keep every camera live at once, higher-priority cameras keep live video and lower-priority cameras fall back to a still image.

There are two kinds of still-image fallback:

- Regular cameras use the latest HomeKit snapshot.
- Cameras marked as battery cameras use a frame captured from a short live session instead of relying on HomeKit snapshots. Battery cameras "borrow" a live feed temporarily from another camera.

This helps battery cameras because their HomeKit snapshots can sometimes be stale, washed out, or slow to update.

## Status Colors

- `Live` with a green dot means the camera is actively streaming.
- `Recent` with a yellow dot means Observe is showing a still image that is still considered fresh.
- `Capturing` with a yellow dot appears only for battery cameras while Observe is briefly using live video to grab a fresh frame.
- `Stale` with a red dot means the still image is too old or the app does not have a trusted image yet.

A red border follows the same idea: it appears when a non-live camera image is stale or missing.

## Requirements

- A modern iPhone
- iOS 18 or later
- Cameras already set up in the Apple Home app
- Xcode 26.4 or later to build and run this project from source

## Run It On Your iPhone

1. Open [Observe.xcodeproj](/Users/kristjanbackmeyer/Code/Observe/Observe.xcodeproj) in Xcode.
2. Connect your iPhone to your Mac.
3. In Xcode, choose your Apple Developer team in Signing for the `Observe` target.
4. Use a unique bundle identifier if needed.
5. Select your iPhone as the run destination.
6. Press Run.
7. When iOS asks for Home access, allow it.

If your cameras already appear in Apple Home on that phone, they should appear in Observe too.

## Notes

- Live video availability depends on HomeKit, your home hub, network conditions, and camera behavior.
- When live video is limited, Observe tries to keep the highest-priority cameras live and keep the remaining images as fresh as possible.
- Battery camera timing can be adjusted in Settings with `Capture Frame After` and `Show As Stale`.
- This project is currently intended for direct install from Xcode, not App Store distribution.
