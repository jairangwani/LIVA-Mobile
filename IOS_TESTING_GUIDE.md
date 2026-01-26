# iOS Mobile SDK Testing Guide

This document explains how to test the LIVA iOS SDK, including building, running tests, and debugging.

---

## Prerequisites

- Xcode installed with iOS Simulator
- Flutter SDK installed
- Maestro CLI installed (`curl -Ls https://get.maestro.mobile.dev | bash`)
- iOS Simulator running (`open -a Simulator`)

---

## Build and Install

### 1. Build the Flutter App for iOS Simulator

```bash
cd /Users/jairangwani/Desktop/LIVA_CODE/LIVA-Mobile/liva-flutter-app
flutter build ios --simulator
```

### 2. Install on Running Simulator

```bash
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
```

### 3. Quick Rebuild Script

For faster iteration:

```bash
# Build + Install in one command
flutter build ios --simulator && xcrun simctl install booted build/ios/iphonesimulator/Runner.app
```

---

## Running Maestro Tests

### Available Test Files

Located in `liva-flutter-app/maestro/`:

| Test File | Description |
|-----------|-------------|
| `flow.yaml` | Basic app flow test |
| `chat_test.yaml` | Chat functionality test |
| `wait_longer.yaml` | Extended wait test for overlay debugging |
| `quick_chat.yaml` | Quick chat interaction test |

### Run a Test

```bash
cd /Users/jairangwani/Desktop/LIVA_CODE/LIVA-Mobile/liva-flutter-app
maestro test maestro/wait_longer.yaml
```

### Test with Screenshots

Screenshots are saved to `maestro/screenshots/`:

```yaml
- takeScreenshot: screenshots/before_message
- takeScreenshot: screenshots/after_response
```

---

## Accessing Debug Logs

The iOS SDK writes debug logs to a file in the app's Documents directory. There are two ways to access them:

### Method 1: Read from Simulator File System

```bash
# Get the app's data container path
APP_CONTAINER=$(xcrun simctl get_app_container booted com.liva.livaApp data)

# Read the full log file
cat "$APP_CONTAINER/Documents/liva_debug.log"

# Search for specific patterns
grep -E "overlay|chunk" "$APP_CONTAINER/Documents/liva_debug.log"

# Watch logs in real-time (while app is running)
tail -f "$APP_CONTAINER/Documents/liva_debug.log"
```

### Method 2: In-App Debug Log Viewer

The chat screen has a debug button in the app bar:

1. Navigate to the chat screen
2. Tap the bug icon (🐛) in the top-right corner
3. A dialog shows the last 500 log entries
4. Logs are scrollable and can be dismissed

### Log Format

Logs include timestamps and component tags:

```
[2026-01-26T10:30:00Z] [LIVASocketManager] 🔌 Connected to server
[2026-01-26T10:30:01Z] [LIVAAnimationEngine] 🎬 Starting overlay chunk 0
[2026-01-26T10:30:02Z] [LIVAAnimationEngine] ✅ Overlay chunk 0 finished
```

### Key Log Patterns to Search For

| Pattern | Meaning |
|---------|---------|
| `🔌 Connected` | Socket connection established |
| `📦 Frame batch` | Overlay frames received |
| `🎬 Starting overlay` | Overlay playback started |
| `✅ Overlay chunk X finished` | Overlay chunk completed |
| `mode=idle` | Animation returned to idle |
| `mode=talking` | Animation in talking/overlay mode |
| `Cache count` | Number of images in cache |

---

## Common Debugging Scenarios

### 1. Socket Connection Issues

Check if connected:
```bash
grep "Connected\|Connection error\|Disconnected" "$APP_CONTAINER/Documents/liva_debug.log"
```

### 2. Overlay Frames Not Appearing

Check if frames are being received and cached:
```bash
grep -E "Frame batch|Cache count|overlay" "$APP_CONTAINER/Documents/liva_debug.log"
```

### 3. Animation Not Playing

Check render loop status:
```bash
grep -E "Draw #|mode=|Starting overlay" "$APP_CONTAINER/Documents/liva_debug.log"
```

### 4. Memory Issues

Check cache eviction:
```bash
grep -E "Evicted|Memory warning|Cache" "$APP_CONTAINER/Documents/liva_debug.log"
```

---

## Xcode Console Logs

For real-time logs during development:

1. Open Xcode
2. Window → Devices and Simulators
3. Select your simulator
4. Open Console
5. Filter by "LIVA" to see SDK logs

Alternatively, use `Console.app`:
1. Open Console.app
2. Select your simulator from the left sidebar
3. Filter: `process:Runner` or search for "LIVA"

---

## Typical Test Workflow

1. **Make code changes** in `liva-sdk-ios/` or Flutter app

2. **Rebuild and install**:
   ```bash
   flutter build ios --simulator && xcrun simctl install booted build/ios/iphonesimulator/Runner.app
   ```

3. **Clear previous logs** (optional):
   ```bash
   APP_CONTAINER=$(xcrun simctl get_app_container booted com.liva.livaApp data)
   rm -f "$APP_CONTAINER/Documents/liva_debug.log"
   ```

4. **Run Maestro test**:
   ```bash
   maestro test maestro/wait_longer.yaml
   ```

5. **Check results**:
   ```bash
   # Check logs
   cat "$APP_CONTAINER/Documents/liva_debug.log" | tail -100

   # Check screenshots
   open maestro/screenshots/
   ```

---

## Troubleshooting

### Maestro Can't Find App

```bash
# Ensure app is installed
xcrun simctl list apps booted | grep liva

# Reinstall if needed
xcrun simctl uninstall booted com.liva.livaApp
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
```

### Logs Not Being Written

- Ensure the app has write permissions to Documents directory
- Check that `LIVADebugLog` is being called (add NSLog statements)
- Verify log file path: `$APP_CONTAINER/Documents/liva_debug.log`

### Simulator Not Responding

```bash
# Reset simulator
xcrun simctl shutdown all
xcrun simctl erase all
open -a Simulator
```

---

## Debug Log Implementation

The SDK uses a file-based logger (`LIVADebugLog`) that:
- Writes to `Documents/liva_debug.log`
- Keeps last 500 entries in memory
- Uses NSLog for console output
- Thread-safe with file locking
- Clears log file on app launch

Location: `liva-sdk-ios/LIVAAnimation/Sources/Core/LIVAAnimationEngine.swift`

To add new log points:
```swift
LIVADebugLog.shared.log("[ComponentName] Your message here")
```

---

## Related Files

- **SDK Source**: `liva-sdk-ios/LIVAAnimation/Sources/Core/`
- **Flutter Plugin**: `liva-flutter-app/ios/Runner/LIVAAnimationPlugin.swift`
- **Dart Interface**: `liva-flutter-app/lib/platform/liva_animation.dart`
- **Chat Screen**: `liva-flutter-app/lib/features/chat/screens/chat_screen.dart`
- **Maestro Tests**: `liva-flutter-app/maestro/`
