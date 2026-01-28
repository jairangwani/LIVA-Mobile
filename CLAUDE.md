# LIVA-Mobile

Mobile SDKs for LIVA AI avatar system (iOS, Android, Flutter).

## Quick Start (iOS)

```bash
cd LIVA-Mobile/liva-sdk-ios

# Open in Xcode
open LIVAAnimation.xcodeproj

# Or use Swift Package Manager
# Add https://github.com/jairangwani/LIVA-Mobile as dependency
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
│           │   └── LIVAConfig.swift           # Configuration
│           ├── Models/                        # Data models
│           ├── Networking/                    # Socket.IO, HTTP
│           └── UI/                            # SwiftUI views
├── liva-sdk-android/                          # Android SDK (future)
├── liva-flutter/                              # Flutter SDK (future)
└── CLAUDE.md                                  # This file
```

---

## Key Files

| File | Purpose |
|------|---------|
| `LIVAClient.swift` | Main SDK class, manages connection and session |
| `LIVAAnimationEngine.swift` | Metal-based animation rendering |
| `LIVASessionLogger.swift` | Sends logs to backend for debugging |
| `LIVAOverlayManager.swift` | Manages lip sync overlay images |

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
cd liva-flutter-app
flutter run -d "iPhone 15 Pro"
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
- Flutter app delays socket connection by 5 seconds after startup
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

**chat_screen.dart (Flutter):**
- 5-second delay before `LIVAAnimation.connect()`
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

**Chunk Synchronization:**
- `pendingBatchCount` tracks async batch operations per chunk
- `chunk_ready` processing deferred if batches still running
- Processed when all batches complete

### Performance Results

- **Cold start:** 0 freezes (was 4-5 @ 100-300ms each)
- **Frame timing:** 33.3ms average (perfect 30fps), 98.5% within target range
- **Warm start:** Occasional 74-213ms freezes at chunk transitions (improvement from 100-300ms)

### Key Files

- `LIVAImageCache.swift` - Decode tracking (`decodedKeys`, `isImageDecoded()`)
- `LIVAAnimationEngine.swift` - Skip-draw, buffer readiness (`shouldSkipFrameAdvance`)
- `LIVAClient.swift` - Batched processing, chunk synchronization (`pendingBatchCount`, `deferredChunkReady`)

### Debugging

Missing animations will cause frame skipping. Check for `MISSING_BASE_ANIM` events in logs. Ensure all animations load before sending first message (~30-40 seconds after app start).

See: [docs/IOS_ASYNC_PROCESSING_PLAN.md](docs/IOS_ASYNC_PROCESSING_PLAN.md) for full implementation details.

---

## Architecture Reference

See main docs: [../CLAUDE.md](../CLAUDE.md)
