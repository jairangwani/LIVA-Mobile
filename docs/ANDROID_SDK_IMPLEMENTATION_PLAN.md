# Android SDK Implementation Plan - iOS/Web Parity

**Goal:** Bring Android SDK to feature parity with iOS SDK and Web frontend for animation rendering, overlay compositing, audio sync, and chunk management.

**Reference Implementations:**
- iOS: `liva-sdk-ios/LIVAAnimation/Sources/`
- Web: `AnnaOS-Interface/src/hooks/videoCanvas/useVideoCanvasLogic.js`
- Android: `liva-sdk-android/liva-animation/src/main/kotlin/`

---

## Executive Summary

The Android SDK has basic Socket.IO connectivity and frame rendering working, but lacks critical features that iOS and Web have for proper animation playback:

| Feature | iOS | Web | Android |
|---------|-----|-----|---------|
| Socket.IO connection | ✅ | ✅ | ✅ |
| Base frame loading | ✅ | ✅ | ✅ |
| Overlay frame decoding | ✅ | ✅ | ✅ |
| **Per-frame overlay coordinates** | ✅ | ✅ | ❌ Missing |
| **Content-based cache keys** | ✅ | ✅ | ⚠️ Partial |
| **Frame sync (matchedSpriteFrameNumber)** | ✅ | ✅ | ❌ Missing |
| **Decode readiness tracking** | ✅ | ✅ | ⚠️ In FrameDecoder only |
| **Buffer readiness (30 frames)** | ✅ | ✅ | ❌ Basic check |
| **Skip-draw-on-wait** | ✅ | ✅ | ❌ Missing |
| **Jitter fix (holdingLastFrame)** | ✅ | ✅ | ❌ Missing |
| **Transition animations** | ✅ | ✅ | ⚠️ Basic |
| **Time-based frame advancement** | ✅ | ✅ | ❌ Simple interval |
| **Audio-animation sync** | ✅ | ✅ | ⚠️ Basic |
| **Session logging** | ✅ | ✅ | ⚠️ Basic |

---

## Phase 1: Data Model Updates (Critical)

### 1.1 Expand DecodedFrame Model

**File:** `Models.kt`

**Current:**
```kotlin
data class DecodedFrame(
    val image: Bitmap,
    val sequenceIndex: Int,
    val animationName: String
)
```

**Target (match iOS OverlayFrame):**
```kotlin
data class DecodedFrame(
    val image: Bitmap,
    val sequenceIndex: Int,
    val animationName: String,
    // NEW FIELDS:
    val coordinates: RectF,              // Position to draw overlay (x, y, width, height)
    val matchedSpriteFrameNumber: Int,   // Base frame number to sync with
    val overlayId: String?,              // Content-based cache key
    val sheetFilename: String,           // Sprite sheet filename
    val char: String?,                   // Character being spoken (for debug)
    val sectionIndex: Int,               // Section within chunk
    val originalFrameIndex: Int          // Original frame index from backend
)
```

### 1.2 Update FrameData Model

**File:** `Models.kt`

**Current:**
```kotlin
data class FrameData(
    // ... existing fields
    @SerializedName("overlay_id") val overlayId: String? = null
)
```

**Add missing fields:**
```kotlin
data class FrameData(
    // ... existing fields
    @SerializedName("overlay_id") val overlayId: String? = null,
    @SerializedName("coordinates") val coordinates: List<Float>? = null,  // [x, y, width, height]
    @SerializedName("zone_top_left") val zoneTopLeft: List<Int>? = null   // Chunk-level position
)
```

### 1.3 Create OverlaySection Model (Match iOS)

**File:** `Models.kt` (new class)

```kotlin
/**
 * Overlay section state tracking (matches iOS OverlayState).
 */
data class OverlaySection(
    val frames: List<DecodedFrame>,
    val chunkIndex: Int,
    val sectionIndex: Int,
    val animationName: String,
    val zoneTopLeft: Pair<Int, Int>,
    val totalFrames: Int,

    // Playback state (mutable)
    var playing: Boolean = false,
    var currentDrawingFrame: Int = 0,
    var done: Boolean = false,
    var holdingLastFrame: Boolean = false,  // JITTER FIX
    var startTime: Long? = null,            // For time-based advancement
    var audioStarted: Boolean = false
)
```

---

## Phase 2: FrameDecoder Enhancements

### 2.1 Preserve Frame Metadata During Decode

**File:** `FrameDecoder.kt`

**Problem:** Current `decodeBatch()` creates `DecodedFrame` without coordinates, matchedSpriteFrameNumber, etc.

**Fix:** Update `decodeBatch()` to pass through all metadata:

```kotlin
suspend fun decodeBatch(batch: FrameBatch): List<DecodedFrame> = withContext(Dispatchers.Default) {
    batch.frames.mapNotNull { frameData ->
        async {
            val (cacheKey, bitmap) = decodeWithContentKey(
                base64String = frameData.imageData,
                overlayId = frameData.overlayId,
                animationName = frameData.animationName,
                spriteNumber = frameData.spriteIndexFolder,
                sheetFilename = frameData.sheetFilename
            )

            bitmap?.let {
                DecodedFrame(
                    image = it,
                    sequenceIndex = frameData.sequenceIndex,
                    animationName = frameData.animationName,
                    // NEW: Preserve all metadata
                    coordinates = parseCoordinates(frameData.coordinates),
                    matchedSpriteFrameNumber = frameData.matchedSpriteFrameNumber,
                    overlayId = cacheKey,
                    sheetFilename = frameData.sheetFilename,
                    char = frameData.char,
                    sectionIndex = frameData.sectionIndex,
                    originalFrameIndex = frameData.frameIndex
                )
            }
        }
    }.awaitAll().filterNotNull().sortedBy { it.sequenceIndex }
}

private fun parseCoordinates(coords: List<Float>?): RectF {
    if (coords == null || coords.size < 4) return RectF()
    return RectF(coords[0], coords[1], coords[0] + coords[2], coords[1] + coords[3])
}
```

---

## Phase 3: AnimationEngine Overhaul

### 3.1 Add OverlaySection State Tracking

**File:** `AnimationEngine.kt`

**Add to class:**
```kotlin
// Overlay section state (matches iOS overlaySectionsRef + overlayStatesRef)
private val overlaySections = mutableListOf<OverlaySection>()
private val overlayQueue = mutableListOf<QueuedOverlayChunk>()

// Current overlay playback state
private var currentOverlayIndex = 0
private var isOverlayPlaying = false

// Jitter fix: Hold last frame while waiting for next chunk
private var holdingLastFrame = false
private var holdingFrameImage: Bitmap? = null
```

### 3.2 Implement Content-Based Frame Lookup

**Current:** Uses positional index `frameQueue[currentFrameIndex]`
**Target:** Use `matchedSpriteFrameNumber` to sync base frame with overlay

```kotlin
/**
 * Get the base frame that matches the current overlay frame.
 * Uses matchedSpriteFrameNumber to ensure lip sync alignment.
 */
private fun getBaseFrameForOverlay(overlay: DecodedFrame): Bitmap? {
    val animationName = overlay.animationName
    val baseFrames = baseAnimations[animationName] ?: return null

    // matchedSpriteFrameNumber tells us which base frame this overlay syncs with
    val baseFrameIndex = overlay.matchedSpriteFrameNumber % baseFrames.size
    return baseFrames.getOrNull(baseFrameIndex)
}
```

### 3.3 Implement Buffer Readiness Check (30 frames)

**Reference:** iOS `isBufferReady()` with `minFramesBeforeStart = 30`

```kotlin
companion object {
    const val MIN_FRAMES_BEFORE_START = 30  // Match iOS/Web
}

/**
 * Check if overlay section has enough decoded frames to start playback.
 * Prevents jitter from starting too early.
 */
private fun isBufferReady(section: OverlaySection): Boolean {
    val requiredFrames = minOf(MIN_FRAMES_BEFORE_START, section.totalFrames)
    var readyCount = 0

    for (i in 0 until requiredFrames) {
        val frame = section.frames.getOrNull(i) ?: break
        val cacheKey = frame.overlayId ?: continue

        // Check BOTH cached AND decoded (not just cached)
        if (frameDecoder.isImageDecoded(cacheKey)) {
            readyCount++
        } else {
            break  // Must be sequential - stop at first gap
        }
    }

    return readyCount >= requiredFrames
}
```

### 3.4 Implement Skip-Draw-On-Wait

**Reference:** iOS `shouldSkipFrameAdvance` and Web's frame hold logic

```kotlin
/**
 * Get next frame for rendering. Returns previous frame if current not ready.
 * This prevents visual desync during async decoding.
 */
fun getNextFrame(): RenderFrame {
    // ... existing base frame logic ...

    if (mode == AnimationMode.TALKING && currentSection != null) {
        val frame = currentSection.frames.getOrNull(currentSection.currentDrawingFrame)

        if (frame != null) {
            val cacheKey = frame.overlayId

            // SKIP-DRAW-ON-WAIT: If overlay not decoded, hold previous frame
            if (cacheKey != null && !frameDecoder.isImageDecoded(cacheKey)) {
                Log.d(TAG, "⏸️ Holding frame - overlay not decoded: $cacheKey")
                return RenderFrame(
                    baseImage = previousBaseFrame,
                    overlayImage = previousOverlayFrame,
                    overlayPosition = previousOverlayPosition
                )
            }

            // Frame is ready - advance
            previousOverlayFrame = frame.image
            previousOverlayPosition = PointF(frame.coordinates.left, frame.coordinates.top)
        }
    }

    // ... continue with frame advancement ...
}
```

### 3.5 Implement Jitter Fix (holdingLastFrame)

**Reference:** iOS `holdingLastFrame` state and Web `holdUntilRef`

```kotlin
/**
 * Check if we should hold the last frame while waiting for next chunk.
 * Prevents blank frame between chunks.
 */
private fun shouldHoldLastFrame(): Boolean {
    if (!isOverlayPlaying) return false

    val currentSection = overlaySections.getOrNull(currentOverlayIndex) ?: return false

    // At or past last frame of current section?
    if (currentSection.currentDrawingFrame >= currentSection.frames.size - 1) {
        // Is there a next chunk queued?
        val nextSection = overlaySections.getOrNull(currentOverlayIndex + 1)
        if (nextSection != null) {
            // Wait for next section buffer to be ready
            if (!isBufferReady(nextSection)) {
                currentSection.holdingLastFrame = true
                Log.d(TAG, "⏸️ Holding last frame - waiting for next chunk buffer")
                return true
            }
        }
    }

    return false
}
```

### 3.6 Implement Time-Based Frame Advancement

**Reference:** iOS `overlayFrameAccumulator` and Web `performance.now()` based advancement

```kotlin
private var lastFrameTime = 0L
private var frameAccumulator = 0.0
private val targetFrameInterval = 1000.0 / 30.0  // 30 FPS = 33.33ms

/**
 * Advance overlay frame based on elapsed time, not render loop ticks.
 * Ensures consistent playback speed regardless of render rate.
 */
private fun advanceOverlayFrame() {
    val currentTime = SystemClock.elapsedRealtime()
    val deltaTime = if (lastFrameTime > 0) currentTime - lastFrameTime else 0L
    lastFrameTime = currentTime

    frameAccumulator += deltaTime

    // Advance frame(s) based on accumulated time
    while (frameAccumulator >= targetFrameInterval) {
        frameAccumulator -= targetFrameInterval

        val section = overlaySections.getOrNull(currentOverlayIndex) ?: break

        // Check if we should hold last frame
        if (shouldHoldLastFrame()) {
            frameAccumulator = 0.0  // Reset accumulator while holding
            break
        }

        // Advance frame
        section.currentDrawingFrame++

        // Check if section is complete
        if (section.currentDrawingFrame >= section.frames.size) {
            section.done = true
            moveToNextSection()
        }
    }
}
```

---

## Phase 4: LIVAClient Updates

### 4.1 Parse Per-Frame Coordinates from Backend

**File:** `LIVAClient.kt` → `handleFrameBatchReceived()`

**Current:** Only stores chunk-level `zoneTopLeft`
**Target:** Parse per-frame `coordinates` from backend

```kotlin
private fun handleFrameBatchReceived(batch: FrameBatch) {
    // ... existing code ...

    // Parse coordinates for each frame
    batch.frames.forEach { frame ->
        // Backend sends coordinates as [x, y, width, height]
        val coords = frame.coordinates
        if (coords != null && coords.size >= 4) {
            // Coordinates are already parsed in FrameData model
            Log.d(TAG, "Frame ${frame.sequenceIndex} coords: $coords")
        }
    }

    // ... continue with decode ...
}
```

### 4.2 Update SocketManager to Parse coordinates

**File:** `SocketManager.kt` → `handleFrameBatchEvent()`

```kotlin
private fun handleFrameBatchEvent(args: Array<Any>) {
    // ... existing parsing ...

    val frame = FrameData(
        // ... existing fields ...
        // ADD: Parse coordinates array
        coordinates = frameObj.optJSONArray("coordinates")?.let { arr ->
            (0 until arr.length()).map { arr.optDouble(it).toFloat() }
        }
    )
}
```

### 4.3 Build OverlaySections in handleChunkReady

**Reference:** iOS `processChunkReady()` builds `OverlayFrame` with coordinates

```kotlin
private fun handleChunkReady(chunkIndex: Int, totalSent: Int) {
    // Get decoded frames for this chunk
    val decodedFrames = pendingDecodedFrames[chunkIndex] ?: return

    // Get overlay position from audio metadata
    val overlayPosition = pendingOverlayPositions[chunkIndex] ?: Pair(0, 0)

    // Build OverlaySection (matches iOS)
    val section = OverlaySection(
        frames = decodedFrames.sortedBy { it.sequenceIndex },
        chunkIndex = chunkIndex,
        sectionIndex = 0,  // Single section per chunk in current backend
        animationName = decodedFrames.firstOrNull()?.animationName ?: "",
        zoneTopLeft = overlayPosition,
        totalFrames = decodedFrames.size
    )

    // Enqueue to animation engine
    animationEngine?.enqueueOverlaySection(section)
}
```

---

## Phase 5: Audio-Animation Sync

### 5.1 Trigger Audio on First Overlay Frame Render

**Reference:** iOS `animationEngine(_:playAudioData:forChunk:)` delegate callback

**Current Android:** Audio queued but timing not synced with first frame render

```kotlin
// In AnimationEngine, when first frame of chunk renders:
private fun onFirstOverlayFrameRendered(chunkIndex: Int) {
    val audioData = queuedAudioChunks[chunkIndex] ?: return

    // Trigger audio playback NOW (matches iOS/Web)
    audioCallback?.invoke(audioData, chunkIndex)

    Log.d(TAG, "🔊 Triggered audio for chunk $chunkIndex on first frame render")
}
```

### 5.2 Add Audio Callback Interface

```kotlin
interface AnimationEngineCallback {
    fun onPlayAudio(audioData: ByteArray, chunkIndex: Int)
    fun onAllChunksComplete()
}
```

---

## Phase 6: Cache Key Consistency

### 6.1 Verify Content-Based Cache Keys Match Backend

**Backend format:** `"{animation_name}/{matched_sprite_frame_number}/{sheet_filename}"`
**Example:** `"talking_1_s_talking_1_e/42/J1_X2_M3.webp"`

**File:** `FrameDecoder.kt` → `decodeWithContentKey()`

```kotlin
/**
 * Generate content-based cache key matching iOS/Web format.
 */
fun generateCacheKey(
    overlayId: String?,
    animationName: String?,
    spriteNumber: Int?,
    sheetFilename: String?
): String {
    // Prefer backend-provided overlay_id
    if (!overlayId.isNullOrEmpty()) {
        return overlayId
    }

    // Fallback: generate from components (must match backend format)
    return if (animationName != null && spriteNumber != null && sheetFilename != null) {
        "$animationName/$spriteNumber/$sheetFilename"
    } else {
        // Last resort - positional key (not recommended)
        UUID.randomUUID().toString()
    }
}
```

### 6.2 Clear Caches on New Message

**Reference:** iOS `forceIdleNow()` and Web `forceIdleNow()`

```kotlin
/**
 * Force transition to idle and clear all caches.
 * MUST be called before sending new message to prevent stale overlay reuse.
 */
fun forceIdleNow() {
    Log.d(TAG, "🔄 forceIdleNow - clearing caches")

    // Stop audio
    audioPlayer?.stop()

    // Clear overlay caches
    frameDecoder.clearAllOverlays()

    // Clear animation state
    overlaySections.clear()
    overlayQueue.clear()
    pendingOverlayPositions.clear()
    pendingDecodedFrames.clear()

    // Reset playback state
    isOverlayPlaying = false
    holdingLastFrame = false
    currentOverlayIndex = 0

    // Transition to idle
    mode = AnimationMode.IDLE
}
```

---

## Phase 7: Transition Animations

### 7.1 Implement Transition Animation Logic

**Reference:** iOS `pendingTransitionRef` and Web `getTransitionAnimation()`

```kotlin
/**
 * Get transition animation name when switching states.
 * Format: {from}_e_{to}_s (e.g., idle_1_e_talking_1_s)
 */
fun getTransitionAnimation(fromAnim: String, toAnim: String): String? {
    val fromMatch = Regex("^([a-z]+_\\d+)").find(fromAnim)
    val toMatch = Regex("^([a-z]+_\\d+)").find(toAnim)

    val fromState = fromMatch?.groupValues?.get(1) ?: return null
    val toState = toMatch?.groupValues?.get(1) ?: return null

    if (fromState == toState) return null

    // Determine end position of current animation
    val endPos = if (fromAnim.endsWith("_s")) "s" else "e"

    return if (endPos == "s") {
        // Need to reach _e first: talking_2_s_talking_2_e
        "${fromState}_s_${fromState}_e"
    } else {
        // Can transition directly: talking_2_e_idle_1_s
        "${fromState}_e_${toState}_s"
    }
}
```

---

## Phase 8: Session Logging Enhancements

### 8.1 Log Frame Details Matching iOS/Web Format

**Reference:** iOS `LIVASessionLogger.logFrame()` and Web `logFrame()`

```kotlin
/**
 * Log frame with full metadata for debugging.
 * Format: timestamp|source|session|chunk|seq|anim|base|overlay|sync|fps|sprite|char|buffer|next_chunk
 */
fun logFrame(
    chunkIndex: Int,
    sequenceIndex: Int,
    animationName: String,
    baseFrameIndex: Int,
    overlayKey: String?,
    syncStatus: String,  // "SYNC" or "DESYNC"
    fps: Float,
    spriteNumber: Int?,
    char: String?,
    bufferStatus: String?,  // "ready/total" e.g., "30/90"
    nextChunkStatus: String?  // "ready/total" for next chunk
) {
    // ... send to backend ...
}
```

---

## Phase 9: Testing & Verification

### 9.1 Test Cases

| Test | Description | Expected |
|------|-------------|----------|
| TC1 | Send message, verify overlay renders | Lip sync visible |
| TC2 | Send message, verify base frame sync | Base frame matches `matchedSpriteFrameNumber` |
| TC3 | Send 3 chunks rapidly | No jitter between chunks |
| TC4 | Send message while previous playing | Old animation stops, new starts |
| TC5 | Verify audio-video sync | Audio starts with first overlay frame |
| TC6 | Memory test (10 messages) | No memory leak |
| TC7 | Compare logs with iOS | Frame counts match |

### 9.2 Debug Commands

```bash
# View Android logs filtered for LIVA
adb logcat -s "LIVAClient" "AnimationEngine" "FrameDecoder" "LIVASocketManager"

# Check frame sync
adb logcat | grep "matchedSprite"

# Check buffer readiness
adb logcat | grep "isBufferReady"

# Check cache keys
adb logcat | grep "STORE key"
```

---

## Implementation Order

1. **Phase 1: Data Models** (Foundation - must do first)
   - [ ] Expand DecodedFrame
   - [ ] Update FrameData
   - [ ] Create OverlaySection

2. **Phase 2: FrameDecoder** (Depends on Phase 1)
   - [ ] Preserve metadata in decodeBatch()
   - [ ] Add parseCoordinates()

3. **Phase 3: AnimationEngine** (Core logic - most work)
   - [ ] Add OverlaySection state tracking
   - [ ] Implement content-based frame lookup
   - [ ] Implement buffer readiness check
   - [ ] Implement skip-draw-on-wait
   - [ ] Implement jitter fix
   - [ ] Implement time-based advancement

4. **Phase 4: LIVAClient** (Wire up new features)
   - [ ] Parse per-frame coordinates
   - [ ] Update SocketManager parsing
   - [ ] Build OverlaySections in handleChunkReady

5. **Phase 5: Audio Sync** (After animation works)
   - [ ] Trigger audio on first frame render
   - [ ] Add callback interface

6. **Phase 6: Cache Keys** (Verification)
   - [ ] Verify key format matches
   - [ ] Implement forceIdleNow()

7. **Phase 7: Transitions** (Polish)
   - [ ] Implement transition logic

8. **Phase 8: Logging** (Debug support)
   - [ ] Enhance frame logging

9. **Phase 9: Testing** (Verification)
   - [ ] Run all test cases
   - [ ] Compare with iOS logs

---

## Files to Modify

| File | Changes |
|------|---------|
| `Models.kt` | Expand DecodedFrame, FrameData, add OverlaySection |
| `FrameDecoder.kt` | Update decodeBatch(), add parseCoordinates() |
| `AnimationEngine.kt` | Major rewrite - overlay sections, buffer check, time-based advancement |
| `LIVAClient.kt` | Parse coordinates, build OverlaySections, forceIdleNow() |
| `SocketManager.kt` | Parse coordinates in frame batch event |
| `LIVACanvasView.kt` | Update to use per-frame coordinates |
| `SessionLogger.kt` | Enhance frame logging format |

---

## Success Criteria

1. **Visual:** Animation plays smoothly with visible lip sync
2. **Audio:** Audio starts exactly when first overlay frame renders
3. **Transitions:** Smooth transitions between idle and talking
4. **No Jitter:** No blank frames between chunks
5. **Memory:** No memory leaks after multiple messages
6. **Logs:** Frame logs match iOS format and counts
7. **User Test:** Matches iOS/Web user experience

---

## References

- iOS `LIVAAnimationEngine.swift` - Line 1-1465
- iOS `LIVAClient.swift` - Line 1-1633
- iOS `LIVAImageCache.swift` - Line 1-479
- iOS `Frame.swift` - Line 1-49
- Web `useVideoCanvasLogic.js` - Line 1-500+ (core logic)
- Android current `AnimationEngine.kt` - Line 1-509
- Android current `LIVAClient.kt` - Line 1-500+

---

**Last Updated:** 2026-01-28
**Author:** Claude Code
