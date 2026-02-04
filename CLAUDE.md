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
│       ├── Views/                             # ChatView, LoginView, AgentSelectionView, SettingsView
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

## Animation Logging

iOS automatically logs frames to the backend session logging system.

**View logs:**
```bash
# Web UI (RECOMMENDED)
open http://localhost:5003/logs

# Sessions appear as: 2026-01-27_HHMMSS_ios
```

---

## Claude Code: Using the Logging System

### How iOS Logging Works

1. **Session starts** when `LIVAClient.connect()` is called
2. **Frames logged** every render cycle in `LIVAAnimationEngine.swift`
3. **Events logged** on chunk start, transitions, errors
4. **Session ends** when `LIVAClient.disconnect()` is called

### Key Integration Points

**LIVAClient.swift:**
```swift
// Configure logger (line ~110)
LIVASessionLogger.shared.configure(serverUrl: config.serverURL)

// Start session (line ~205)
LIVASessionLogger.shared.startSession(userId: userId, agentId: agentId)

// End session (line ~151)
LIVASessionLogger.shared.endSession()
```

**LIVAAnimationEngine.swift:**
```swift
// Log chunk start (line ~451)
LIVASessionLogger.shared.logEvent("CHUNK_START", details: [
    "chunk": chunkIndex,
    "frames": frameCount
])

// Log frame (line ~607)
LIVASessionLogger.shared.logFrame(
    chunk: currentChunkIndex,
    seq: currentOverlaySeq,
    anim: currentOverlayBaseName,
    baseFrame: baseFrameNum,
    overlayKey: currentOverlayKey,
    syncStatus: isInSync ? "SYNC" : "DESYNC",
    fps: currentFPS
)
```

### Adding Custom Debug Logs

```swift
import LIVAAnimation

// Log an event
LIVASessionLogger.shared.logEvent("MY_DEBUG_EVENT", details: [
    "chunk": chunkIndex,
    "reason": "something happened",
    "value": 123
])

// Check if session is active
if LIVASessionLogger.shared.isSessionActive {
    // Logging is enabled
}

// Disable logging (if needed)
LIVASessionLogger.shared.isEnabled = false
```

### Log Format

iOS logs use source `IOS`:
```
timestamp|IOS|session|chunk|seq|anim|base|overlay|sync|fps|||
```

**Example:**
```
2026-01-27T10:30:45.123|IOS|2026-01-27_103045_ios|0|24|talking_2_s_e|4|J1_X2_M0.webp|SYNC|30.0|||
```

**Note:** iOS doesn't send `char`, `buffer`, `next_chunk` fields (these are frontend-specific debug data).

### Debugging Tips

1. **Check session created:** Look for `[LIVASessionLogger] Started session:` in Xcode console
2. **View logs:** Open http://localhost:5003/logs, select the `_ios` session
3. **Compare with web:** Run same interaction on web and iOS, compare frame logs
4. **Look for DESYNC:** Check if sprite numbers match between backend and iOS

### Common Issues

**No logs appearing:**
- Check `LIVASessionLogger.shared.isEnabled` is true
- Verify backend URL is correct
- Check network connectivity to backend

**Session not starting:**
- Ensure `configure(serverUrl:)` is called before `startSession()`
- Check backend is running on expected port

---

## Testing iOS (CRITICAL - Use Test Script)

**Do NOT type manually in the iOS app to test. Use the test script.**

### Quick Start

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
./scripts/ios-test.sh                    # Default "Hello from test script"
./scripts/ios-test.sh "Custom message"   # Custom message
```

### What the Test Script Does

`LIVA-TESTS/scripts/ios-test.sh`:
1. Checks backend is running at localhost:5003
2. Finds active iOS session
3. Sends HTTP POST to `/messages` endpoint
4. Waits for animation to complete
5. Reports: BACKEND frames sent vs IOS frames rendered
6. Reports any DESYNC errors

### Viewing Logs

```bash
# Web UI (best)
open http://localhost:5003/logs

# CLI - latest iOS session
SESSION=$(ls -t ../LIVA-TESTS/logs/sessions | grep _ios | head -1)
cat ../LIVA-TESTS/logs/sessions/$SESSION/events.log
cat ../LIVA-TESTS/logs/sessions/$SESSION/frames.log | head -50

# Check sync status
grep "DESYNC" ../LIVA-TESTS/logs/sessions/$SESSION/frames.log | wc -l
```

### Comparing iOS vs Web

```bash
# 1. Clear sessions
rm -rf ../LIVA-TESTS/logs/sessions/2026-*

# 2. Test web - open http://localhost:3005, send message

# 3. Test iOS - use test script
./scripts/ios-test.sh "Same message as web"

# 4. Compare in http://localhost:5003/logs
# Look for differences in:
#   - Chunk timing
#   - Frame sequence
#   - Sync status
#   - Animation transitions
```

### Test Script Output Example

```
=== iOS Animation Test ===
Message: Hello world
✓ Backend running
✓ iOS session: 2026-01-27_120754_ios
Sending message...
✓ Message sent
Waiting for animation...

=== Results ===
Session:        2026-01-27_120754_ios
New frames:     1090
Backend sent:   650
iOS rendered:   1189
Chunks:         8
DESYNC errors:  0
✓ Test PASSED - All frames in sync
```

---

---

## iOS Startup Optimization (2026-01-28)

### Overview

The iOS SDK implements instant startup with synchronous single-frame loading and accurate FPS tracking from app launch.

### Architecture

**Synchronous Frame Loading:**
- Frame 0 loaded synchronously on main thread during `attachView()`
- No async/batched loading overhead at startup
- Rendering starts immediately with single frame
- Additional frames load on-demand when backend requests them

**FPS Tracking:**
- Tracks from app start (configure() call), not first frame render
- Logs first 100 frames with accurate timestamps
- Detects blocking (frames taking >100ms)
- Writes to `/tmp/fps_startup.log` for analysis

**Cache System:**
- `hasCachedAnimation()` checks for `frame_0000.png` (not manifest.json)
- `loadSingleFrame()` uses 4-digit zero-padded filenames
- Only checks cache existence at startup, doesn't load frames
- Defers frame loading until needed by backend

**Socket Connection Deferral:**
- Native iOS app delays socket connection by 5 seconds after initialization
- Allows render loop to stabilize before network operations
- Reduces main thread blocking during initialization

### Performance Results

**SDK Performance:**
- ✅ First frame renders at +1.0s from app start
- ✅ Frame 0 loads from cache in ~7ms
- ✅ Stable 60 FPS after frame 10

**Simulator Overhead:**
- Frames 4-8 show stuttering (4.8 → 0.1 FPS) due to iOS Simulator JIT compilation
- This occurs regardless of SDK code (tested with async, sync, test frames)
- Expected to be absent on real iOS devices

### Key Changes

**LIVAAnimationEngine.swift:**
- `setAppStartTime()` - Set reference time for accurate FPS tracking
- Logs frames with format: `+X.XXXs from app start | delta: XXms | fps: XX.X`
- Blocking detection for frames >100ms

**LIVAClient.swift:**
- `loadCachedAnimationsIntoEngine()` - Synchronous single-frame loading
- Removed async/batched loading complexity
- Simplified startup path: load frame 0 → start rendering → done

**BaseFrameManager.swift:**
- `hasCachedAnimation()` - Checks for frame_0000.png existence
- `loadSingleFrame()` - Fixed filename format (4-digit padding)
- No longer loads all frames at startup

**ChatViewModel.swift (Native iOS app):**
- 5-second delay before `LIVAClient.shared.connect()`
- Allows iOS render loop to stabilize

### Testing & Verification

**FPS Logging:**
```bash
# Check startup FPS
tail -f /tmp/fps_startup.log

# Expected output:
# 🎬 [FRAME 1] First frame rendered at +1.023s from app start!
# 📊 [FRAME 1] +1.024s from app start | delta: 1.1ms | fps: 891.4 | mode: idle
# 📊 [FRAME 2] +1.039s from app start | delta: 16.7ms | fps: 60.0 | mode: idle
# 📊 [FRAME 3] +1.052s from app start | delta: 16.7ms | fps: 60.0 | mode: idle
```

**Startup Timing:**
```bash
# Check detailed startup timing
cat /tmp/startup_timing.log

# Expected milestones:
# [0.000s] ⚙️ configure() START
# [0.124s] ⚙️ configure() END
# [0.993s] 📱 attachView() START
# [1.000s] ✅ Frame 0 loaded synchronously
# [1.000s] 🎉 Rendering started immediately!
# [1.001s] 📱 attachView() END
```

### Known Issues

**Simulator Stuttering:**
- Frames 4-8 stutter on iOS Simulator (JIT/Metal compilation overhead)
- Not caused by SDK code (verified with multiple approaches)
- Should be absent on real devices
- Recommendation: Test on physical iPhone for accurate performance

### Debugging

**FPS drops:**
- Check `/tmp/fps_startup.log` for blocking detection warnings
- Look for frames with delta >100ms
- Verify frame timing from app start

**Black screen at startup:**
- Check if frame 0 exists in cache
- Verify `hasCachedAnimation()` returns true
- Check console for "Frame 0 loaded synchronously" message

**Animation not loading:**
- Animations load on-demand when backend requests them
- Check backend sends correct animation names
- Look for `MISSING_BASE_ANIM` warnings in logs

---

## iOS Async Frame Processing (2026-01-27)

### Overview

The iOS SDK implements batched async frame processing to prevent main thread blocking during overlay frame arrival. This matches the web frontend's approach and eliminates freezing during playback.

### Architecture

**Batched Processing with Yields:**
- First frame processed immediately (synchronous) for buffer readiness check
- Remaining frames processed in batches of 15 with `DispatchQueue.main.async` yields
- Matches web frontend's `setTimeout(0)` pattern

**Decode Tracking:**
- `LIVAImageCache` tracks which images are fully decoded via `decodedKeys: Set<String>`
- `isImageDecoded(forKey:)` distinguishes "cached" from "render-ready"
- Buffer readiness checks both cached AND decoded status

**Skip-Draw-on-Wait:**
- When overlay not decoded, animation holds previous frame
- Frame counter doesn't advance on skip
- Prevents visual desync during async decoding
- **SKIP_DRAW timeout:** After 15 consecutive skips (~500ms), force-advances past stuck frame to prevent infinite freeze. Counter resets on successful render or mode change.

**Chunk Eviction (cross-chunk safety):**
- `evictChunks()` removes cached images from completed chunks to free memory
- **Shared-key protection:** Before evicting a key, checks if any remaining active chunk also uses it. Prevents cross-chunk content key collisions from destroying images still needed by later chunks. (See `docs/lessons/MOBILE.md` for full bug description.)

**Chunk Synchronization:**
- `pendingBatchCount` tracks async batch operations per chunk
- `chunk_ready` processing deferred if batches still running
- Processed when all batches complete

### Performance Results

- **Cold start:** 0 freezes (was 4-5 @ 100-300ms each)
- **Frame timing:** 33.3ms average (perfect 30fps), 98.5% within target range
- **Warm start:** Occasional 74-213ms freezes at chunk transitions (improvement from 100-300ms)

### Key Files

- `LIVAImageCache.swift` - Decode tracking (`decodedKeys`, `isImageDecoded()`), cross-chunk eviction with shared-key protection
- `LIVAAnimationEngine.swift` - Skip-draw with timeout (`shouldSkipFrameAdvance`, `maxConsecutiveSkipDraws`), buffer readiness
- `LIVAClient.swift` - Batched processing, chunk synchronization (`pendingBatchCount`, `deferredChunkReady`), frame loss detection

### Debugging

Missing animations will cause frame skipping. Check for `MISSING_BASE_ANIM` events in logs. Ensure all animations load before sending first message (~30-40 seconds after app start).

See: [docs/IOS_ASYNC_PROCESSING_PLAN.md](docs/IOS_ASYNC_PROCESSING_PLAN.md) for full implementation details.

---

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

### Testing Android

**Use native test app, NOT Flutter:**

```bash
# 1. Start backend
cd AnnaOS-API && python main.py

# 2. Cold boot emulator + setup port forwarding
adb reverse tcp:5003 tcp:5003

# 3. Install and run test app
cd LIVA-Mobile/liva-android-app
./gradlew installDebug
adb shell am start -n com.liva.testapp/.MainActivity

# 4. Send test message (use instance_id: "android_test")
curl -X POST http://localhost:5003/messages \
  -H "Content-Type: application/json" \
  -H "X-User-ID: test_user_android" \
  -d '{"AgentID": "1", "instance_id": "android_test", "message": "Hello"}'

# 5. View logs
adb logcat -s "LIVAClient" "LIVASocketManager" "AnimationEngine" "SessionLogger"
```

### Android Socket.IO Library

Uses Dyte's SocketIO-Kotlin library (NOT official Java client):

```kotlin
// build.gradle
implementation("io.dyte:socketio-kotlin:1.0.8")
```

**Why Dyte library:** Official Java client uses Engine.IO v3, incompatible with backend's Engine.IO v4. Dyte library works correctly with Flask-SocketIO 5.x.

### Android Feature Parity with iOS

| Feature | iOS | Android |
|---------|-----|---------|
| Session logging | LIVASessionLogger | SessionLogger.kt |
| Async frame processing | Batched with yields | Batched with delay(0) |
| Animation state machine | Mode enum | AnimationMode enum |
| Buffer readiness (30 frames) | isBufferReady() | MIN_FRAMES_BEFORE_START=30 |
| Skip-draw-on-wait | shouldSkipFrameAdvance | Skip-draw in getNextFrame |
| Audio-video sync | Callback on first frame | triggerAudioForChunk callback |
| Progressive loading | Idle first | Idle first |
| Chunk synchronization | pendingBatchCount | pendingBatchCount |

### Critical Instance ID Note

The Android test app uses `instanceId = "android_test"`:

```kotlin
// MainActivity.kt
val config = LIVAConfiguration(
    serverUrl = "http://localhost:5003",  // works via adb reverse
    userId = "test_user_android",
    agentId = "1",
    instanceId = "android_test"  // MUST match when sending test messages
)
```

Room name format: `{user_id}-{agent_id}-instance-{instance_id}`
Example: `test_user_android-1-instance-android_test`

---

## CRITICAL: Backend Socket.IO Emit Pattern (2026-01-28)

### The Problem

**Android clients DO NOT receive events** emitted with `socketio.emit()` from background greenlets.

Events from socket handlers (like `receive_base_frame`) work fine.
Events from background greenlets (like `receive_audio`, `receive_frame_images_batch`) do NOT reach Android.

### Root Cause

Flask-SocketIO's `socketio.emit()` requires socket handler context. When called from an `eventlet.spawn()` greenlet (background processing), it silently fails for some clients (Android in particular).

### The Fix

**Use `socketio.server.emit()` with explicit `namespace='/'` for ALL emissions from background greenlets:**

```python
# WRONG - Works for web, but NOT for Android from background greenlets
socketio.emit('receive_audio', data, room=room_name)

# CORRECT - Works for ALL clients (web, iOS, Android)
socketio.server.emit('receive_audio', data, room=room_name, namespace='/')
```

### Files Modified

- `AnnaOS-API/managers/stream_handler.py` - All emit calls updated
- `AnnaOS-API/managers/main_stream_manager.py` - All emit calls updated

### Events Affected

These events are emitted from background greenlets and MUST use `socketio.server.emit()`:

| Event | File | Purpose |
|-------|------|---------|
| `receive_audio` | stream_handler.py | Audio chunk + animation data |
| `receive_frame_images_batch` | stream_handler.py | Overlay images |
| `chunk_images_ready` | stream_handler.py | Images ready signal |
| `receive_frame_image` | stream_handler.py | Single frame (legacy) |
| `new_image` | main_stream_manager.py | Generated images |
| `play_base_animation` | main_stream_manager.py | Idle transition |
| `audio_end` | main_stream_manager.py | Processing complete |
| `new_message` | main_stream_manager.py | Text messages |

### How to Debug

1. Add a test emit in socket handler (like `connect_user`):
   ```python
   socketio.emit('test_ping', {'msg': 'from handler'}, room=room_name)
   ```
   This WILL reach Android.

2. Add same emit from background greenlet:
   ```python
   socketio.emit('test_ping', {'msg': 'from greenlet'}, room=room_name)
   ```
   This will NOT reach Android.

3. Fix:
   ```python
   socketio.server.emit('test_ping', {'msg': 'from greenlet'}, room=room_name, namespace='/')
   ```
   Now it reaches Android.

### Verification

Check backend logs for:
```
[SID_LOOKUP] Room 'test_user_android-1-instance-android_test' found: [sid]
```

If room found but Android not receiving events, the emit pattern is wrong.

---

## Gotchas (Android)

See also: [../docs/lessons/MOBILE.md](../docs/lessons/MOBILE.md) for full lessons learned.

- Use `adb reverse tcp:5003 tcp:5003` + `localhost` (NOT `10.0.2.2`, unreliable on API 34)
- Cold boot emulator when starting dev sessions (networking stack can corrupt)
- Use `socketio.server.emit(..., namespace='/')` from background greenlets (NOT `socketio.emit()`)
- Use Dyte SocketIO-Kotlin library (NOT official Java Socket.IO client)
- Always match `instance_id` when sending test messages
- Use native test app (`liva-android-app`), NOT Flutter for Android testing

---

## Architecture Reference

- **Client Animation Pipeline (master workflow):** [../docs/architecture/CLIENT_ANIMATION_PIPELINE.md](../docs/architecture/CLIENT_ANIMATION_PIPELINE.md) — 8-phase rendering pipeline, per-platform implementation maps, known bugs, debugging guide. **Read this first when debugging animation issues.**
- **iOS SDK integration:** [../docs/architecture/IOS_SDK_INTEGRATION.md](../docs/architecture/IOS_SDK_INTEGRATION.md)
- **iOS async processing:** [../docs/architecture/IOS_ASYNC_PROCESSING.md](../docs/architecture/IOS_ASYNC_PROCESSING.md)
- **Android SDK integration:** [../docs/architecture/ANDROID_SDK_INTEGRATION.md](../docs/architecture/ANDROID_SDK_INTEGRATION.md)
- **Full system overview:** [../CLAUDE.md](../CLAUDE.md)
