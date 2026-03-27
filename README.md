# Observe

Observe is a fast, minimal iPhone app for viewing Apple Home security cameras.

The goal is simple: open the app and see your cameras as quickly as possible, with the cleanest possible layout.

## What It Does

- Shows cameras from your Apple Home setup in a simple wall view
- Prioritizes live video when HomeKit allows it
- Falls back to recent snapshots when live video is limited
- Keeps the interface focused on the camera image, camera name, and current status
- Hides offline cameras from the main wall until they come back online

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
- When live video is limited, Observe tries to keep snapshots as recent as possible.
- This project is currently intended for direct install from Xcode, not App Store distribution.
