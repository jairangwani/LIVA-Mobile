# Android SDK - Next Steps to Audio/Video Playback

**Goal:** Android SDK plays audio and video overlays exactly like Web and iOS.

**Date:** 2026-01-28

---

## Current State

### What Works
- [x] Socket.IO connection (Dyte library)
- [x] Room joining (`{user_id}-{agent_id}-instance-{instance_id}`)
- [x] Backend socket emissions fixed (`socketio.server.emit` with `namespace='/'`)
- [x] Base frame loading from cache
- [x] SDK code structure (LIVAClient, AnimationEngine, FrameDecoder, SocketManager)
- [x] Native test app (`liva-android-app`)

### What's Untested/Unknown
- [ ] Does Android actually RECEIVE `receive_audio` events now?
- [ ] Does Android actually RECEIVE `receive_frame_images_batch` events now?
- [ ] Does audio actually PLAY through speakers?
- [ ] Do overlay frames actually RENDER on screen?
- [ ] Does lip sync match audio?

### Critical Fix Applied (2026-01-28)
Backend was using `socketio.emit()` from background greenlets - this works for Web but NOT for Android.

**Fixed:** Changed to `socketio.server.emit(..., namespace='/')` in:
- `AnnaOS-API/managers/stream_handler.py`
- `AnnaOS-API/managers/main_stream_manager.py`

---

## Lessons Learned (CRITICAL - Read Before Coding)

### 1. Backend Socket.IO Emit Pattern
```python
# WRONG - Android doesn't receive from background greenlets
socketio.emit('event', data, room=room_name)

# CORRECT - All clients receive
socketio.server.emit('event', data, room=room_name, namespace='/')
```

### 2. Use Native Android SDK, NOT Flutter
- Flutter app has missing `AndroidManifest.xml` issues
- Use `liva-android-app` (native Kotlin) for testing
- Flutter is iOS only for now

### 3. Instance ID Must Match
- Android test app uses `instanceId = "android_test"`
- Test messages MUST use same `instance_id: "android_test"`
- Room format: `{user_id}-{agent_id}-instance-{instance_id}`

### 4. Android Emulator Localhost
- Use `10.0.2.2` for localhost from Android emulator
- NOT `localhost` or `127.0.0.1`

### 5. Socket.IO Library
- Use Dyte SocketIO-Kotlin (`io.dyte:socketio-kotlin:1.0.8`)
- NOT official Java Socket.IO client (compatibility issues)

---

## Testing Strategy

### Phase 1: Verify Socket Events Received

**Objective:** Confirm Android SDK receives `receive_audio` and `receive_frame_images_batch` events.

**Steps:**
1. Start backend: `cd AnnaOS-API && python main.py`
2. Start Android emulator: `emulator -avd <avd_name>`
3. Install test app: `cd liva-android-app && ./gradlew installDebug`
4. Launch app and wait for socket connection
5. Check logcat for: `LIVA: Connected to socket`
6. Send test message:
   ```bash
   curl -X POST http://localhost:5003/messages \
     -H "Content-Type: application/json" \
     -H "X-User-ID: test_user_android" \
     -d '{"AgentID": "1", "instance_id": "android_test", "message": "Hello"}'
   ```
7. Check logcat for:
   - `receive_audio` event received
   - `receive_frame_images_batch` event received
   - Audio chunk data (base64 length, chunk index)
   - Frame batch data (frame count, chunk index)

**Verification Command:**
```bash
adb logcat -s "LIVAClient" "LIVASocketManager" "AnimationEngine" | grep -E "(receive_audio|receive_frame|chunk)"
```

**Success Criteria:**
- [ ] `receive_audio` events logged for chunks 0, 1, 2, 3
- [ ] `receive_frame_images_batch` events logged
- [ ] `chunk_images_ready` events logged

### Phase 2: Verify Audio Playback

**Objective:** Confirm audio actually plays through device speakers.

**Steps:**
1. Check logcat for AudioPlayer logs
2. Listen for audio from emulator/device
3. If no audio:
   - Check AudioPlayer initialization
   - Check ExoPlayer/MediaPlayer setup
   - Check audio data decoding (base64 to PCM/MP3)

**Verification Command:**
```bash
adb logcat -s "AudioPlayer" "LIVAAudio" | grep -E "(play|audio|decode)"
```

**Success Criteria:**
- [ ] Audio audible from device
- [ ] Audio plays for each chunk
- [ ] No audio overlap between chunks

### Phase 3: Verify Overlay Rendering

**Objective:** Confirm overlay frames render on screen.

**Steps:**
1. Watch the avatar on screen while sending message
2. Check for lip movement overlays
3. Check logcat for render logs
4. If no overlays visible:
   - Check FrameDecoder is decoding frames
   - Check AnimationEngine is receiving decoded frames
   - Check Canvas is drawing overlays at correct position

**Verification Command:**
```bash
adb logcat -s "AnimationEngine" "FrameDecoder" "LIVACanvasView" | grep -E "(render|draw|overlay|frame)"
```

**Success Criteria:**
- [ ] Lip sync overlays visible on avatar
- [ ] Overlays positioned correctly
- [ ] Overlays change with audio

### Phase 4: End-to-End Sync Test

**Objective:** Audio and video play in sync like Web/iOS.

**Steps:**
1. Record screen while playing
2. Compare with Web frontend recording
3. Check for:
   - Audio starts when first overlay renders
   - No jitter between chunks
   - Smooth transition back to idle

**Success Criteria:**
- [ ] Audio-video sync matches Web
- [ ] No visible jitter
- [ ] Clean idle transition after response

---

## Debugging Playbook

### Problem: No Events Received

**Check:**
1. Backend running? `curl http://localhost:5003/health`
2. Socket connected? Look for `LIVA: Connected` in logcat
3. Room joined? Look for `joined room` in logcat
4. Backend emitting? Check `/tmp/backend_live.log` for `EMIT receive_audio`

**Fix:**
- Verify `socketio.server.emit()` used (not `socketio.emit()`)
- Verify room name matches: `test_user_android-1-instance-android_test`

### Problem: Events Received but No Audio

**Check:**
1. AudioPlayer initialized? Look for `AudioPlayer: init` in logcat
2. Audio data valid? Log base64 length, should be >1000 bytes
3. Audio decoded? Look for decode errors

**Fix:**
- Check audio format (MP3/PCM)
- Check ExoPlayer/MediaPlayer configuration
- Check audio output routing

### Problem: Events Received but No Overlays

**Check:**
1. Frames decoded? Look for `FrameDecoder: decoded X frames` in logcat
2. AnimationEngine receiving? Look for `enqueue` logs
3. Canvas drawing? Look for `onDraw` logs

**Fix:**
- Check FrameDecoder is processing batches
- Check AnimationEngine overlay queue
- Check Canvas invalidation

### Problem: Audio/Video Out of Sync

**Check:**
1. Audio triggers on first frame render?
2. Frame advancement time-based?
3. Buffer readiness check working?

**Fix:**
- Implement audio callback on first overlay render
- Use time-based advancement (not render-loop ticks)
- Verify 30-frame buffer before playback

---

## File Reference

### SDK Files (liva-sdk-android)
| File | Purpose |
|------|---------|
| `LIVAClient.kt` | Main SDK entry, connection management |
| `SocketManager.kt` | Socket.IO event handling |
| `AnimationEngine.kt` | Animation state, frame rendering |
| `FrameDecoder.kt` | Base64 to Bitmap decoding |
| `BaseFrameManager.kt` | Base frame cache |
| `Models.kt` | Data classes |

### Test App Files (liva-android-app)
| File | Purpose |
|------|---------|
| `MainActivity.kt` | Test app entry point |
| `build.gradle` | Dependencies |

### Backend Files (AnnaOS-API)
| File | Purpose |
|------|---------|
| `managers/stream_handler.py` | Audio/frame streaming |
| `managers/main_stream_manager.py` | Message processing |
| `api/websocket/connection_handlers.py` | Socket connection |

---

## Commands Quick Reference

```bash
# Start backend
cd AnnaOS-API && python main.py

# Start frontend (for comparison)
cd AnnaOS-Interface && npm run dev

# Build and install Android app
cd LIVA-Mobile/liva-android-app && ./gradlew installDebug

# View Android logs
adb logcat -s "LIVAClient" "LIVASocketManager" "AnimationEngine" "FrameDecoder" "AudioPlayer"

# Send test message
curl -X POST http://localhost:5003/messages \
  -H "Content-Type: application/json" \
  -H "X-User-ID: test_user_android" \
  -d '{"AgentID": "1", "instance_id": "android_test", "message": "Hello"}'

# Check backend logs
tail -f /tmp/backend_live.log | grep -E "(android|EMIT|receive_audio)"

# View log viewer UI
open http://localhost:5003/logs
```

---

## Implementation Checklist

### If Events Not Received
- [ ] Verify `socketio.server.emit()` with `namespace='/'` in all stream handlers
- [ ] Verify room name format matches
- [ ] Verify Dyte Socket.IO library version

### If Audio Not Playing
- [ ] Implement/fix AudioPlayer initialization
- [ ] Handle MP3 audio format from backend
- [ ] Connect audio playback to `receive_audio` event

### If Overlays Not Rendering
- [ ] Verify FrameDecoder outputs Bitmaps
- [ ] Verify AnimationEngine receives decoded frames
- [ ] Verify Canvas draws overlays at correct coordinates

### If Out of Sync
- [ ] Trigger audio on first overlay frame render (not on receive)
- [ ] Use time-based frame advancement
- [ ] Implement 30-frame buffer check before playback start

---

## Success Definition

Android SDK is complete when:

1. **Audio plays** - You can hear the AI response
2. **Overlays render** - You can see lip sync on avatar
3. **In sync** - Audio matches lip movement
4. **No jitter** - Smooth playback between chunks
5. **Clean transitions** - Smooth idle -> talking -> idle

Compare side-by-side with Web frontend - should be identical experience.

---

## Next Session Startup

When starting fresh conversation:

1. Read this document first
2. Read `LIVA-Mobile/CLAUDE.md` for architecture
3. Start with Phase 1: Verify Socket Events Received
4. Follow debugging playbook if issues found
5. Progress through phases sequentially

---

**Previous Plan:** `docs/_archive_ANDROID_SDK_IMPLEMENTATION_PLAN.md` (detailed implementation reference)
