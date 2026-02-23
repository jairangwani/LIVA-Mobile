# LIVA-Mobile

Mobile SDKs and native apps for LIVA AI avatar system (iOS, Android).

---

## Quick Start (iOS)

```bash
cd LIVA-Mobile/liva-ios-app

# Open in Xcode
open LIVAApp.xcodeproj

# Or build from CLI
xcodebuild -scheme LIVAApp -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```

**Requires:** Backend running on http://localhost:5003

---

## Project Structure

```
LIVA-Mobile/
├── liva-sdk-ios/
│   └── LIVAAnimation/
│       └── Sources/
│           ├── Core/
│           │   ├── LIVAClient.swift           # Main SDK entry point
│           │   ├── LIVAAnimationEngine.swift  # Animation rendering (Metal)
│           │   ├── LIVASessionLogger.swift    # Session-based logging
│           │   ├── SocketManager.swift        # Socket.IO connection
│           │   ├── Configuration.swift        # SDK configuration
│           │   ├── LIVAImageCache.swift       # Image decode tracking
│           │   └── CacheKeyGenerator.swift    # Cache utilities
│           ├── Models/                        # Frame, AnimationChunk, AgentConfig
│           ├── Rendering/                     # CanvasView, BaseFrameManager, FrameDecoder
│           ├── Audio/                         # AudioPlayer
│           └── Diagnostics/                   # LIVAPerformanceTracker
├── liva-sdk-android/
│   └── liva-animation/
│       └── src/main/kotlin/com/liva/animation/
│           ├── core/
│           │   ├── LIVAClient.kt              # Main SDK entry point
│           │   ├── SocketManager.kt           # Socket.IO connection (Dyte library)
│           │   └── Configuration.kt           # SDK configuration
│           ├── rendering/
│           │   ├── AnimationEngine.kt         # Animation state, frame rendering
│           │   ├── BaseFrameManager.kt        # Base frame cache
│           │   ├── FrameDecoder.kt            # Base64 → Bitmap decoding
│           │   └── LIVACanvasView.kt          # SurfaceView rendering
│           ├── audio/
│           │   ├── AudioPlayer.kt             # MP3 playback (ExoPlayer)
│           │   └── AudioSyncManager.kt        # Audio-video sync
│           ├── logging/
│           │   └── SessionLogger.kt           # Session-based logging (matches iOS)
│           └── models/
│               └── Models.kt                  # Data classes
├── liva-ios-app/                               # Native SwiftUI iOS app
│   └── LIVAApp/                               # App source (SwiftUI, uses liva-sdk-ios via SPM)
│       ├── Views/                             # ChatView, AgentSelectionView, LoginView, SettingsView
│       ├── ViewModels/                        # ChatViewModel, AuthViewModel, AgentViewModel
│       ├── Models/                            # Message
│       └── Config/                            # AppConfig
├── liva-android-app/                          # Native Kotlin Android app
│   └── app/src/main/java/com/liva/testapp/
│       └── MainActivity.kt                    # App entry point (uses liva-sdk-android)
└── CLAUDE.md                                  # This file
```

---

## Key Files (iOS)

| File | Purpose |
|------|---------|
| `LIVAClient.swift` | Main SDK class, manages connection and session |
| `LIVAAnimationEngine.swift` | Metal-based animation rendering |
| `LIVASessionLogger.swift` | Sends logs to backend for debugging |
| `BaseFrameManager.swift` | Base frame cache and overlay management |
| `LIVAImageCache.swift` | Decode tracking (`decodedKeys`, `isImageDecoded()`) |

## Key Files (Android)

| File | Purpose |
|------|---------|
| `LIVAClient.kt` | Main SDK class, manages connection and session |
| `AnimationEngine.kt` | Animation state machine, frame rendering, audio-video sync |
| `SocketManager.kt` | Socket.IO connection (Dyte library) |
| `SessionLogger.kt` | Session-based logging (matches iOS format) |
| `BaseFrameManager.kt` | Base frame cache |
| `FrameDecoder.kt` | Base64 → Bitmap with async batch decoding |

---

## Knowledge Graph

Use genome MCP tools for contracts and mobile lessons:
- `genome_search "socket event"` -- find Socket.IO event contracts
- `genome_search "mobile"` -- find mobile-specific entities and lessons
- `genome_search "ios"` or `genome_search "android"` -- platform-specific context
- `genome_brief <file>` -- briefing before editing a file

---

## iOS Testing (Use Test Script)

**Do NOT type manually in the iOS app. Use the test script.**

```bash
# 1. Ensure backend is running
cd ../AnnaOS-API && python main.py

# 2. Start iOS app in simulator
cd liva-ios-app
xcodebuild -scheme LIVAApp -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/LIVAApp-*/Build/Products/Debug-iphonesimulator/LIVAApp.app
xcrun simctl launch booted com.liva.app
# WAIT 20+ seconds for socket to fully connect

# 3. Send test messages via script
cd ../LIVA-TESTS
./scripts/ios-test.sh                    # Default message
./scripts/ios-test.sh "Custom message"   # Custom message
```

Wait 20+ seconds after app launch before sending messages (socket needs to connect).

View logs: http://localhost:5003/logs

---

## iOS Async Frame Processing

Batched async processing prevents main thread blocking during overlay frame arrival:
- First frame processed immediately, remaining in batches of 15
- `LIVAImageCache` tracks decoded status via `decodedKeys: Set<String>`
- Skip-draw-on-wait: holds previous frame when overlay not decoded
- `pendingBatchCount` tracks async operations for chunk synchronization

Use `genome_search "ios async"` for full details.

---

## Android SDK (Native Kotlin)

**IMPORTANT: Use native Android SDK, NOT Flutter for Android testing.**

### Quick Start (Android)

```bash
# 1. Cold boot emulator (networking fix for API 34)
# Android Studio > Device Manager > "..." > "Cold Boot Now"

# 2. Setup port forwarding (required instead of 10.0.2.2)
adb reverse tcp:5003 tcp:5003

# 3. Build and install
cd LIVA-Mobile/liva-android-app
./gradlew installDebug
```

**Requires:** Backend running on http://localhost:5003 (via `adb reverse`, NOT `10.0.2.2`)

### Critical Instance ID Note

The Android test app uses `instanceId = "android_test"`. Room name format: `{user_id}-{agent_id}-instance-{instance_id}`.

---

## Gotchas

- Use `adb reverse tcp:5003 tcp:5003` + `localhost` (NOT `10.0.2.2`, unreliable on API 34)
- Cold boot emulator when starting dev sessions (networking stack can corrupt)
- Use `socketio.server.emit(..., namespace='/')` from background greenlets (NOT `socketio.emit()`)
- Always match `instance_id` when sending test messages
- Use native test app (`liva-android-app`), NOT Flutter for Android testing

For mobile lessons and gotchas: `genome_search "mobile"` or `genome_search "android"`

---

## Testing

**ALL tests go in `../LIVA-TESTS/`** -- not in this repository.

Mobile gotchas: `genome_search "mobile"` or `genome_search "android"` / `genome_search "ios"`
