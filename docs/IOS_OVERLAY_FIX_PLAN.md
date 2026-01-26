# iOS Overlay Rendering Fix Plan

## Executive Summary

The iOS implementation has several issues that were already fixed in the web frontend. This document outlines the required changes to bring iOS in line with the proven web implementation.

---

## Web vs iOS Comparison

This section provides a side-by-side comparison of how the animation playback works in both platforms. The web frontend is the reference implementation (proven working).

### Animation Playback Flow

| Step | Web (React/JS) | iOS (Swift) | Status |
|------|----------------|-------------|--------|
| 1. Receive chunk | Socket `receive_frame_images_batch` | Socket `receive_frame_images_batch` | ✅ Same |
| 2. Cache image | `overlayFrameImagesRef.set(overlay_id, img)` | `imageCache.setImage(img, key: positional)` | ❌ Different keys |
| 3. Check buffer ready | Uses `overlay_id` keys | Uses positional keys | ❌ iOS wrong |
| 4. Start playback | `state.playing = true` | `state.playing = true` | ✅ Same |
| 5. Get base frame | `getOverlayDrivenBaseFrame()` | `getOverlayDrivenBaseFrame()` | ⚠️ Logic differs |
| 6. Lookup overlay | Uses `overlay_id` | Uses positional key | ❌ iOS wrong |
| 7. Advance frame | No `skipFirstAdvance` | Has `skipFirstAdvance` | ❌ iOS has bug |
| 8. Transition to idle | `transitionToIdle()` | `transitionToIdle()` | ✅ Same |

### Cache Key Format

| Platform | Key Format | Example | Correct? |
|----------|------------|---------|----------|
| **Web** | `overlay_id` from backend | `"talking_1_s_talking_1_e/7/J1_X2_M2.webp"` | ✅ Yes |
| **iOS** | `chunkIndex_sectionIndex_sequenceIndex` | `"0_0_5"` | ❌ No - positional |

**Why overlay_id is correct:**
- Content-based: same image = same key (deduplication)
- Self-documenting: key tells you exactly what image it is
- Robust: no wrong images if cache clearing fails

### Base Frame Index Calculation

| Platform | Logic | Code |
|----------|-------|------|
| **Web** | Use backend value directly | `const baseFrameIndex = Number(overlayFrame.matched_sprite_frame_number \|\| 0);` |
| **iOS** | Apply modulo | `let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount` |

**Analysis:** iOS applies modulo while web uses the backend value directly. The backend already provides the correct index (it knows the frame count). iOS's modulo could cause issues if the backend value is already correct.

**Recommendation:** iOS should use backend value directly like web, OR verify that backend always sends raw index requiring modulo.

### Animation Name Switching Within Chunks

**Web (CORRECT - per-frame):**
```javascript
// In getOverlayDrivenBaseFrame():
const animName = overlayFrame.animation_name || currentBaseName;
// Each frame can have different animation_name
```

**iOS (INCORRECT - section-level):**
```swift
// In getOverlayDrivenBaseFrame():
let animName = section.frames[0].animationName
// Uses first frame's animation name for entire section
```

**Problem:** Within a single chunk, animation names can change (e.g., `idle_1_e_talking_1_s` → `talking_1_s_talking_1_e`). iOS using only the first frame's name will miss mid-chunk transitions.

**Fix:** iOS should read `animation_name` from each frame individually, like web does.

### skipFirstAdvance Bug

| Platform | Has Bug? | Consequence |
|----------|----------|-------------|
| **Web** | ❌ No (removed) | Clean chunk transitions |
| **iOS** | ✅ Yes | Frame 0 draws twice → jitter |

**Code showing the bug (iOS LIVAAnimationEngine.swift lines 714-718):**
```swift
if state.skipFirstAdvance {
    state.skipFirstAdvance = false
    overlayStates[index] = state
    continue  // ← Skips advancement, frame 0 will draw again
}
```

### Decode Readiness Tracking

| Platform | Tracks Decode? | Method |
|----------|----------------|--------|
| **Web** | ✅ Yes | `img._decoded` flag set after `img.decode().then()` |
| **iOS** | ❌ No | Only checks `hasImage(forKey:)` - no decode check |

### Skip-Frame-If-Not-Ready Logic

| Platform | Has Skip? | Behavior |
|----------|-----------|----------|
| **Web** | ✅ Yes | Keeps showing previous frame if overlay not decoded |
| **iOS** | ❌ No | Draws base without overlay → jitter |

---

## CRITICAL ARCHITECTURE DIFFERENCES

The following are **fundamental architectural differences** between web and iOS that MUST be addressed for the animation system to work correctly.

### 10. **CRITICAL: No Idle Animation Pingpong (Missing)**

**Web behavior:**
```javascript
// In idle mode, when animation ends:
if (currentOverlayBaseNameRef.current === IDLE_ANIMATION) nextAnim = IDLE_BACK_ANIMATION;
else if (currentOverlayBaseNameRef.current === IDLE_BACK_ANIMATION) nextAnim = IDLE_ANIMATION;
// Alternates: idle_1_s_idle_1_e → idle_1_e_idle_1_s → idle_1_s_idle_1_e
```

**iOS behavior:**
```swift
// In advanceIdleFrame():
if nextFrame >= baseFrames.count {
    currentOverlayBaseName = defaultIdleAnimation  // Always resets to same animation
    globalFrameIndex = 0
}
```

**Problem:** iOS idle loops the SAME animation repeatedly instead of pingponging between `_s_e` and `_e_s` variants. This may look unnatural.

---

### 11. **CRITICAL: No Transition Animation Playback**

**Web has sophisticated transition handling:**
```javascript
// When starting overlays from idle:
if (modeRef.current === "idle" && transitionAnim && canUseFrames(transitionAnim)) {
    currentOverlayBaseNameRef.current = transitionAnim;  // e.g., "idle_1_e_talking_1_s"
    globalFrameIndexRef.current = 0;
    modeRef.current = "transition";  // Play transition BEFORE overlays
    pendingTransitionRef.current = { transitionAnim, targetAnim, pendingOverlay };
    return;  // Don't start overlays yet
}
```

**iOS does NOT have this:**
- iOS has `ANIMATION_LOAD_ORDER` with transition animations defined
- iOS has `AnimationMode.transition` enum case
- **BUT there is NO CODE to actually play transition animations!**
- iOS jumps directly from idle to overlay mode

**Impact:** Animation will "pop" instead of smooth transition between idle and talking.

---

### 12. **CRITICAL: No finishingBase/returnTransition Modes**

**Web state machine:**
```
idle → transition → overlay → finishingBase → returnTransition → idle
```

**iOS state machine:**
```
idle ↔ overlay (no intermediate states)
```

**Web's finishingBase mode:**
```javascript
// When overlays done but base animation hasn't finished all frames:
modeRef.current = "finishingBase";
pendingReturnTransitionRef.current = "talking_1_e_idle_1_s";
// Continues playing base until it reaches end frame, THEN plays return transition
```

**Web's returnTransition mode:**
```javascript
// After finishingBase completes:
currentOverlayBaseNameRef.current = "talking_1_e_idle_1_s";  // Return transition
globalFrameIndexRef.current = 0;
modeRef.current = "returnTransition";
// Plays talking→idle transition, THEN goes to idle
```

**iOS does NOT have these modes!** It jumps directly to idle:
```swift
func transitionToIdle() {
    mode = .idle
    currentOverlayBaseName = defaultIdleAnimation  // JUMPS directly!
    globalFrameIndex = 0
}
```

**Impact:** Animation will "pop" from talking to idle instead of smooth transition.

---

### 13. **CRITICAL: No holdingLastFrame for Chunk Transitions**

**Web behavior:**
```javascript
// In advanceOverlays, at last frame of chunk:
if (overlayQueueRef.current.length > 0) {
    if (!isBufferReady(nextSection)) {
        state.holdingLastFrame = true;  // DON'T mark done yet
        return;  // Keep showing last frame until buffer ready
    }
}
```

**iOS does NOT have this:**
```swift
if state.currentDrawingFrame >= section.frames.count {
    state.playing = false
    state.done = true  // Marks done immediately, no buffer check
}
```

**Impact:** Gap/jitter between chunks if next chunk's buffer isn't ready.

---

### 14. **Idle FPS Difference (10fps vs 30fps)**

| Platform | Idle FPS | Overlay FPS |
|----------|----------|-------------|
| **Web** | 10 fps | 30 fps |
| **iOS** | 30 fps | 30 fps |

**iOS code (line 141-142):**
```swift
private let idleFrameDuration: CFTimeInterval = 1.0 / 30.0  // 30 FPS for idle
```

**Impact:** iOS uses 3x more CPU for idle animation. Not a bug, but inefficient.

---

## Issues Identified

### 1. **CRITICAL: Positional Cache Keys Instead of overlay_id**

**Location:** `LIVAAnimationTypes.swift` line 156-158, `LIVAClient.swift` lines 324-333

**Current (WRONG):**
```swift
func getOverlayKey(chunkIndex: Int, sectionIndex: Int, sequenceIndex: Int) -> String {
    return "\(chunkIndex)_\(sectionIndex)_\(sequenceIndex)"
}
// Example: "0_0_5" - positional, can map to wrong image
```

**Problem:**
- Same key could map to different images if cache isn't cleared properly
- No deduplication - same image at different positions cached twice
- Keys don't describe content

**Fix (Use overlay_id):**
```swift
// Use backend's overlay_id as cache key
func getContentKey(overlayId: String?) -> String? {
    return overlayId  // e.g., "talking_1_s_talking_1_e/7/J1_X2_M2.webp"
}
```

---

### 2. **CRITICAL: skipFirstAdvance Causing Double-Draw**

**Location:** `LIVAAnimationTypes.swift` line 66, `LIVAAnimationEngine.swift` (advanceOverlays)

**Current (WRONG):**
```swift
struct OverlayState {
    var skipFirstAdvance: Bool = true  // THIS CAUSES JITTER
    // ...
}
```

**Problem:**
- Frame 0 is drawn twice at chunk start
- Same bug we just fixed in web frontend
- Causes visible jitter at chunk transitions

**Fix:** Remove `skipFirstAdvance` entirely. The `getOverlayDrivenBaseFrame()` already handles synchronization.

---

### 3. **Missing Decode Readiness Check**

**Location:** `LIVAImageCache.swift`, `LIVAAnimationEngine.swift`

**Current:**
- Only checks if image EXISTS in cache (`hasImage(forKey:)`)
- Doesn't track if image is fully decoded and ready to render

**Problem:**
- May try to render image still being decoded
- Can cause brief visual glitches

**Fix:** Add `_decoded` equivalent tracking:
```swift
class LIVAImageCache {
    private var decodedStatus: [String: Bool] = [:]

    func isImageReady(forKey key: String) -> Bool {
        return cache.object(forKey: key as NSString) != nil
            && decodedStatus[key] == true
    }

    func setImage(_ image: UIImage, forKey key: String, decoded: Bool = true) {
        cache.setObject(image, forKey: key as NSString)
        decodedStatus[key] = decoded
    }
}
```

---

### 4. **No Skip-Frame-If-Overlay-Not-Ready Logic**

**Location:** `LIVAAnimationEngine.swift` draw loop

**Current:**
- Draws base frame even if overlay not ready
- Can cause jitter (base without overlay for one frame)

**Fix:** Add skip logic like web frontend:
```swift
// In draw loop, BEFORE drawing:
if let overlayDriven = getOverlayDrivenBaseFrame() {
    let overlayKey = getContentKey(overlayId: overlayDriven.overlayFrame.overlayId)
    if let key = overlayKey, !imageCache.isImageReady(forKey: key) {
        // Skip this frame - keep showing previous frame
        return  // Don't clear canvas, don't draw, don't advance
    }
}
```

---

### 5. **Buffer Check Uses Wrong Key Format**

**Location:** `LIVAAnimationEngine.swift` lines 904-927 (`isBufferReady`)

**Current:**
```swift
let key = getOverlayKey(chunkIndex: section.chunkIndex, sectionIndex: section.sectionIndex, sequenceIndex: i)
if imageCache.hasImage(forKey: key) { ... }
```

**Problem:** Uses positional key, should use overlay_id from frame data

**Fix:**
```swift
private func isBufferReady(_ section: OverlaySection) -> Bool {
    let framesToCheck = min(section.frames.count, minFramesBeforeStart)

    for i in 0..<framesToCheck {
        let frame = section.frames[i]
        guard let key = frame.overlayId else { continue }  // Use overlay_id

        if !imageCache.isImageReady(forKey: key) {
            return false  // Stop at first not-ready frame
        }
    }

    return true
}
```

---

### 6. **Missing Cache Clear on New Message**

**Location:** `LIVAAnimationEngine.swift` `forceIdleNow()`

**Current:** May not fully clear overlay cache when user sends new message

**Fix:** Ensure complete cache clear:
```swift
func forceIdleNow() {
    mode = .idle
    globalFrameIndex = 0

    // Clear ALL overlay state
    overlaySections.removeAll()
    overlayStates.removeAll()
    overlayQueue.removeAll()
    isSetPlaying = false

    // CRITICAL: Clear cache to prevent stale frames
    imageCache.clearAll()
    imageCache.clearDecodedStatus()  // New method

    // Clear audio
    pendingAudioChunks.removeAll()
    audioStartedForChunk.removeAll()
}
```

---

### 7. **Debug Step Mode Missing**

**Location:** N/A (doesn't exist)

**Recommendation:** Add debug step mode for troubleshooting (like web frontend):
- Toggle with tap gesture or debug flag
- Step forward/back through frames
- Log frame data at each step

---

### 8. **CRITICAL: Per-Frame Animation Name Not Used**

**Location:** `LIVAAnimationEngine.swift` lines 637-638, 652-653

**Current (WRONG):**
```swift
// Uses first frame's animation name for ENTIRE section
let animName = section.frames[0].animationName
```

**Problem:**
- Within a chunk, animation names can change mid-playback
- Example: Frame 0-10 might be `idle_1_e_talking_1_s`, frames 11-50 are `talking_1_s_talking_1_e`
- iOS ignores per-frame animation name, causing wrong base frame selection

**Web (CORRECT):**
```javascript
// Uses animation_name from EACH frame
const animName = overlayFrame.animation_name || currentBaseName;
```

**Fix:**
```swift
// In getOverlayDrivenBaseFrame():
let overlayFrame = section.frames[state.currentDrawingFrame]
let animName = overlayFrame.animationName  // Use THIS frame's name, not first frame's
```

---

### 9. **Base Frame Index Uses Modulo (Inconsistent with Web)**

**Location:** `LIVAAnimationEngine.swift` lines 639, 654

**Current:**
```swift
let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount
```

**Web (Different):**
```javascript
const baseFrameIndex = Number(overlayFrame.matched_sprite_frame_number || 0);
// No modulo - uses backend value directly
```

**Analysis:**
- The backend provides `matched_sprite_frame_number` which should be the exact index to use
- Web trusts backend value; iOS applies modulo
- If backend sends correct index (which it should), iOS modulo is unnecessary
- If backend sends running index, modulo is needed

**Recommendation:** Verify backend behavior, then either:
1. Remove modulo (align with web), OR
2. Document that modulo is intentional (if backend sends running index)

---

## Implementation Plan

### Phase 1: Cache Key Migration (High Priority)

**Files to modify:**
1. `LIVAAnimationTypes.swift` - Add `getContentKey()` function
2. `LIVAClient.swift` - Use overlay_id when caching images
3. `LIVAImageCache.swift` - Accept overlay_id keys
4. `LIVAAnimationEngine.swift` - Use overlay_id for lookups

**Steps:**
1. Add `getContentKey(overlayId:)` helper function
2. Update `processAndCacheOverlayImageAsync` to use overlay_id as key
3. Update `isBufferReady` to use overlay_id keys
4. Update `isFirstOverlayFrameReady` to use overlay_id keys
5. Update draw loop overlay lookup to use overlay_id

### Phase 2: Remove skipFirstAdvance (High Priority)

**Files to modify:**
1. `LIVAAnimationTypes.swift` - Remove from OverlayState
2. `LIVAAnimationEngine.swift` - Remove all skipFirstAdvance checks

**Steps:**
1. Remove `skipFirstAdvance` property from `OverlayState`
2. Remove skip logic in `advanceOverlays()` (lines 714-718)
3. Remove setting `skipFirstAdvance = true` when starting playback (line 444, line 893)
4. Test chunk transitions for jitter

### Phase 2.5: Fix Per-Frame Animation Name (High Priority)

**Files to modify:**
1. `LIVAAnimationEngine.swift` - Use per-frame animation name

**Steps:**
1. In `getOverlayDrivenBaseFrame()`, change line 637-638:
   ```swift
   // BEFORE: let animName = section.frames[0].animationName
   // AFTER:
   let overlayFrame = section.frames[state.currentDrawingFrame]
   let animName = overlayFrame.animationName
   ```
2. Similarly fix lines 652-653 for the `shouldStartPlaying` case
3. Test mid-chunk animation name transitions

### Phase 3: Add Decode Readiness Tracking (Medium Priority)

**Files to modify:**
1. `LIVAImageCache.swift` - Add decoded status tracking

**Steps:**
1. Add `decodedStatus` dictionary
2. Add `isImageReady(forKey:)` method
3. Update `setImage` to mark as decoded
4. Update all callers to use `isImageReady` instead of `hasImage`

### Phase 4: Add Skip-Frame-If-Not-Ready (Medium Priority)

**Files to modify:**
1. `LIVAAnimationEngine.swift` - Add skip logic in draw loop

**Steps:**
1. Check overlay readiness BEFORE drawing
2. If not ready, return early (don't clear/draw/advance)
3. Add logging when skip occurs

### Phase 5: Add Debug Tools (Low Priority)

**Files to modify:**
1. `LIVAAnimationEngine.swift` - Add debug step mode
2. `LIVACanvasView.swift` - Add tap gesture for toggle

**Steps:**
1. Add `debugStepMode` flag
2. Add `stepForward()` and `stepBack()` methods
3. Add gesture recognizer for toggling
4. Add detailed frame logging in step mode

---

## Phase 6: Idle Animation Pingpong (Medium Priority)

**Files to modify:**
1. `LIVAAnimationEngine.swift` - `advanceIdleFrame()`

**Steps:**
1. Add `alternateIdleAnimation` constant (`idle_1_e_idle_1_s`)
2. In `advanceIdleFrame()`, when animation ends:
   ```swift
   if nextFrame >= baseFrames.count {
       // Switch to alternate idle animation (pingpong)
       let nextAnim: String
       if currentOverlayBaseName == "idle_1_s_idle_1_e" {
           nextAnim = "idle_1_e_idle_1_s"
       } else {
           nextAnim = "idle_1_s_idle_1_e"
       }
       if animationFrames[nextAnim]?.count > 0 {
           currentOverlayBaseName = nextAnim
           globalFrameIndex = 0
       } else {
           globalFrameIndex = 0  // Fallback: loop same animation
       }
   }
   ```
3. Test idle animation looks natural (no "pop" at loop boundary)

---

## Phase 7: Transition Animation Playback (HIGH PRIORITY)

**Files to modify:**
1. `LIVAAnimationEngine.swift` - `startNextOverlaySetIfAny()`

**Steps:**
1. Add `pendingTransitionRef` to store pending overlay during transition
2. Add `getTransitionAnimation()` function:
   ```swift
   func getTransitionAnimation(from: String, to: String) -> String? {
       // Extract base state names
       let fromMatch = from.prefix(while: { $0 != "_" }) + "_" + from[...]
       // Return: e.g., "idle_1_e_talking_1_s" or "talking_1_e_idle_1_s"
   }
   ```
3. In `startNextOverlaySetIfAny()`, BEFORE starting overlays:
   ```swift
   if mode == .idle {
       let transitionAnim = getTransitionAnimation(from: currentOverlayBaseName, to: animation_name)
       if let trans = transitionAnim, animationFrames[trans]?.count > 0 {
           // Play transition FIRST
           currentOverlayBaseName = trans
           globalFrameIndex = 0
           mode = .transition
           pendingTransitionRef = pendingOverlay  // Store overlay for later
           return  // Don't start overlay yet
       }
   }
   ```
4. In draw loop, when `mode == .transition`:
   ```swift
   if mode == .transition {
       // Check if transition animation finished
       if globalFrameIndex >= animationFrames[currentOverlayBaseName]?.count ?? 0 {
           // Transition done - now start the pending overlay
           mode = .overlay
           // ... start pending overlay
       }
   }
   ```
5. Test: idle → talking transition plays smoothly

---

## Phase 8: finishingBase and returnTransition Modes (HIGH PRIORITY)

**Files to modify:**
1. `LIVAAnimationEngine.swift` - `cleanupOverlays()`, draw loop
2. `LIVAAnimationTypes.swift` - Add modes to enum

**Steps:**
1. Add new AnimationMode cases:
   ```swift
   enum AnimationMode {
       case idle
       case overlay
       case transition
       case finishingBase      // NEW: Waiting for base animation to finish
       case returnTransition   // NEW: Playing talking→idle transition
   }
   ```

2. Add tracking refs:
   ```swift
   private var pendingReturnTransition: String? = nil
   private var finishingBaseTargetFrame: Int? = nil
   ```

3. In `cleanupOverlays()`, when all overlays done:
   ```swift
   if active.isEmpty && overlayQueue.isEmpty {
       // Calculate return transition
       let returnTransitionAnim = getTransitionAnimation(from: currentOverlayBaseName, to: "idle_1_s_idle_1_e")

       if let returnAnim = returnTransitionAnim {
           let targetFrameCount = animationFrames[currentOverlayBaseName]?.count ?? 0

           if globalFrameIndex < targetFrameCount - 1 {
               // Base not finished - enter finishingBase mode
               mode = .finishingBase
               pendingReturnTransition = returnAnim
               finishingBaseTargetFrame = targetFrameCount
           } else if animationFrames[returnAnim]?.count > 0 {
               // Base finished, return transition loaded - play it
               currentOverlayBaseName = returnAnim
               globalFrameIndex = 0
               mode = .returnTransition
           }
       } else {
           // No transition - go directly to idle
           transitionToIdle()
       }
   }
   ```

4. In draw loop, handle finishingBase:
   ```swift
   if mode == .finishingBase {
       let targetCount = finishingBaseTargetFrame ?? baseFrames.count
       let next = globalFrameIndex + 1

       if next >= targetCount {
           // Base finished - play return transition
           if let returnAnim = pendingReturnTransition,
              animationFrames[returnAnim]?.count > 0 {
               currentOverlayBaseName = returnAnim
               globalFrameIndex = 0
               mode = .returnTransition
               pendingReturnTransition = nil
               finishingBaseTargetFrame = nil
           } else {
               transitionToIdle()
           }
       } else {
           globalFrameIndex = next
       }
   }
   ```

5. In draw loop, handle returnTransition:
   ```swift
   if mode == .returnTransition {
       let targetCount = baseFrames.count
       let next = globalFrameIndex + 1

       if next >= targetCount {
           transitionToIdle()
       } else {
           globalFrameIndex = next
       }
   }
   ```

6. Test: talking → idle plays full base animation, then transition, then idle

---

## Phase 9: holdingLastFrame for Chunk Transitions (HIGH PRIORITY)

**Files to modify:**
1. `LIVAAnimationTypes.swift` - Add `holdingLastFrame` to OverlayState
2. `LIVAAnimationEngine.swift` - `advanceOverlays()`

**Steps:**
1. Add to OverlayState:
   ```swift
   var holdingLastFrame: Bool = false
   ```

2. In `advanceOverlays()`, at last frame check:
   ```swift
   let isLastFrame = state.currentDrawingFrame >= section.frames.count - 1

   if isLastFrame {
       // Check if next chunk buffer is ready
       if !overlayQueue.isEmpty {
           let nextChunk = overlayQueue.first!
           if !isBufferReady(nextChunk.section) {
               // Buffer NOT ready - hold at last frame
               state.holdingLastFrame = true
               animLog("⏸️ HOLDING: Chunk \(section.chunkIndex) waiting for next chunk buffer")
               return  // Don't mark done yet
           }
       }

       // Buffer ready (or no more chunks) - mark done
       state.playing = false
       state.done = true
       state.holdingLastFrame = false
   }
   ```

3. In `advanceOverlays()`, skip if holding:
   ```swift
   if state.holdingLastFrame {
       return  // Stay on last frame
   }
   ```

4. Test: No gap between chunks even on slow network

---

## Phase 10: Idle FPS Optimization (LOW PRIORITY)

**Files to modify:**
1. `LIVAAnimationEngine.swift` - Change idle frame duration

**Steps:**
1. Change idle frame rate from 30fps to 10fps:
   ```swift
   private let idleFrameDuration: CFTimeInterval = 1.0 / 10.0  // 10 FPS for idle (was 30)
   ```

2. Test idle animation still looks smooth at lower FPS

---

## Files to Modify

| File | Changes |
|------|---------|
| `LIVAAnimationTypes.swift` | Add `getContentKey()`, remove `skipFirstAdvance`, add `holdingLastFrame`, add new AnimationMode cases |
| `LIVAAnimationEngine.swift` | **MAJOR REWRITE**: Use overlay_id, remove skipFirstAdvance, fix per-frame animation name, add transition/finishingBase/returnTransition modes, add holdingLastFrame logic, idle pingpong |
| `LIVAImageCache.swift` | Add decoded tracking, `isImageReady()`, `clearDecodedStatus()` |
| `LIVAClient.swift` | Use overlay_id when caching images |
| `LIVACanvasView.swift` | Debug gesture (optional) |
| `SocketManager.swift` | Ensure `overlay_id` is parsed from backend frame data |

---

## Testing Plan

### Unit Tests
1. Cache key generation with overlay_id
2. Buffer readiness check with overlay_id
3. Image decoded status tracking

### Integration Tests
1. Chunk transition without jitter
2. New message clears old overlays
3. Frame sync verification (base matches overlay data)

### Manual Tests
1. Play multiple chunks, verify smooth transitions
2. Send new message mid-playback, verify clean reset
3. Enable debug logging, verify frame sync
4. Test on slow network (buffer wait scenarios)

### Test Commands
```bash
cd LIVA-TESTS
npm run test:ios          # Run iOS unit tests
npm run test:ios:e2e      # Run iOS E2E tests
```

---

## Verification Checklist

### Cache System
- [ ] Cache keys use `overlay_id` format (not positional)
- [ ] `getContentKey(overlayId:)` function exists
- [ ] All cache lookups use overlay_id
- [ ] `isImageReady()` checks BOTH existence AND decoded status

### skipFirstAdvance Removal
- [ ] No `skipFirstAdvance` property in `OverlayState`
- [ ] No skip logic in `advanceOverlays()`
- [ ] No `skipFirstAdvance = true` assignments anywhere

### Per-Frame Animation Name
- [ ] `getOverlayDrivenBaseFrame()` reads animation name from CURRENT frame
- [ ] NOT from `section.frames[0].animationName`
- [ ] Mid-chunk animation transitions work correctly

### Frame Skip Logic
- [ ] Draw loop skips frame if overlay not ready
- [ ] Previous frame continues showing (no blank/base-only)
- [ ] Logging when skip occurs

### State Cleanup
- [ ] `forceIdleNow()` clears all overlay caches
- [ ] `forceIdleNow()` clears decoded status tracking
- [ ] New message doesn't show old overlay images

### Rendering Quality
- [ ] No jitter at chunk transitions
- [ ] No jitter at mid-chunk animation name changes
- [ ] Frame sync logs show matching base/overlay indices
- [ ] Smooth playback at 30 FPS

### Animation Transitions (NEW - CRITICAL)
- [ ] Idle animation pingpongs between `_s_e` and `_e_s` variants
- [ ] Transition animation plays when going idle → talking (e.g., `idle_1_e_talking_1_s`)
- [ ] Transition animation plays when going talking → idle (e.g., `talking_1_e_idle_1_s`)
- [ ] `finishingBase` mode waits for base animation to complete before return transition
- [ ] `returnTransition` mode plays the talking→idle transition
- [ ] `holdingLastFrame` prevents gaps between chunks
- [ ] No "pop" when entering or exiting talking mode

### State Machine
- [ ] `AnimationMode` enum has: idle, overlay, transition, finishingBase, returnTransition
- [ ] State transitions match web: idle → transition → overlay → finishingBase → returnTransition → idle
- [ ] Each mode handled correctly in draw loop

---

## Risk Assessment

| Change | Risk | Mitigation |
|--------|------|------------|
| Cache key format change | Images not found | Dual-key support during migration |
| Remove skipFirstAdvance | Unknown side effects | Test thoroughly, easy rollback |
| Decode tracking | Memory overhead | Minimal (just Bool dictionary) |
| Skip frame logic | Animation stutter | Only skips if overlay truly not ready |
| Per-frame animation name | Wrong base frames briefly | Test mid-chunk transitions |
| Modulo removal (if done) | Index out of bounds | Add bounds check as safety |
| **Idle pingpong** | Animation mismatch | Ensure both idle variants loaded |
| **Transition playback** | **HIGH**: Breaks if transition not loaded | Check animation loaded before entering transition mode |
| **finishingBase mode** | **HIGH**: Base may never finish | Add timeout fallback to idle |
| **returnTransition mode** | **HIGH**: Transition may never load | Add timeout, fallback to idle |
| **holdingLastFrame** | Stuck on last frame forever | Add max hold time, force advance |

### High-Risk Mitigations

**Transition animation not loaded:**
```swift
// Before entering transition mode:
guard animationFrames[transitionAnim]?.count > 0 else {
    // Fallback: skip transition, go directly to overlay
    return
}
```

**finishingBase never completes:**
```swift
// Add timeout in finishingBase mode:
if timeInFinishingBase > 5.0 {  // 5 second timeout
    animLog("⚠️ finishingBase timeout - forcing idle")
    transitionToIdle()
}
```

**holdingLastFrame stuck:**
```swift
// Add max hold time:
if holdDuration > 1.0 {  // 1 second max
    animLog("⚠️ holdingLastFrame timeout - marking done")
    state.done = true
    state.holdingLastFrame = false
}
```

---

## Rollback Plan

Each change can be reverted independently:
1. Keep `getOverlayKey()` for fallback
2. Re-add `skipFirstAdvance` if needed (unlikely)
3. Remove decoded tracking if memory issues
4. Disable skip logic with flag

---

## Timeline Estimate

### Bug Fixes (MUST DO)
- Phase 1 (Cache Keys): 2-3 hours
- Phase 2 (skipFirstAdvance): 30 minutes
- Phase 2.5 (Per-Frame Animation Name): 30 minutes
- Phase 3 (Decode Tracking): 1 hour
- Phase 4 (Skip Logic): 1 hour

### Architecture Alignment (CRITICAL - Required for proper animation)
- Phase 6 (Idle Pingpong): 30 minutes
- Phase 7 (Transition Playback): 2-3 hours **HIGH PRIORITY**
- Phase 8 (finishingBase/returnTransition): 3-4 hours **HIGH PRIORITY**
- Phase 9 (holdingLastFrame): 1 hour **HIGH PRIORITY**

### Optional Improvements
- Phase 5 (Debug Tools): 2 hours
- Phase 10 (Idle FPS Optimization): 30 minutes

### Testing
- Unit/Integration Testing: 2-3 hours
- E2E Testing: 2-3 hours

**Bug Fixes Only: 5-6 hours**
**Full Implementation (Bug Fixes + Architecture): 16-20 hours**

### Recommended Implementation Order

1. **Phase 2** (skipFirstAdvance) - Quick win, removes jitter
2. **Phase 2.5** (Per-Frame Animation Name) - Critical for correct base frames
3. **Phase 9** (holdingLastFrame) - Prevents chunk gaps
4. **Phase 1** (Cache Keys) - Better caching/deduplication
5. **Phase 7** (Transition Playback) - Smooth idle→talking
6. **Phase 8** (finishingBase/returnTransition) - Smooth talking→idle
7. **Phase 6** (Idle Pingpong) - Natural idle animation
8. **Phase 3** (Decode Tracking) - Prevents decode jitter
9. **Phase 4** (Skip Logic) - Prevents rendering glitches
10. **Phase 5** (Debug Tools) - Optional, for troubleshooting
11. **Phase 10** (Idle FPS) - Optional, performance improvement

---

## Reference Implementation (Web Frontend)

These files contain the working implementation to reference:

| Web File | Purpose | iOS Equivalent |
|----------|---------|----------------|
| `AnnaOS-Interface/src/hooks/videoCanvas/useVideoCanvasLogic.js` | Main render loop, frame advancement | `LIVAAnimationEngine.swift` |
| `AnnaOS-Interface/src/hooks/videoCanvas/utils/drawHelpers.js` | `getOverlayDrivenBaseFrame()`, `isOverlayFrameReady()` | `LIVAAnimationEngine.swift` (same functions) |
| `AnnaOS-Interface/src/hooks/videoCanvas/utils/frameHelpers.js` | `getContentKey()`, `drawFeatheredSprite()` | `LIVAAnimationTypes.swift`, `LIVACanvasView.swift` |
| `AnnaOS-Interface/docs/OVERLAY_RENDERING_SYSTEM.md` | Complete system documentation | This document |

### Key Web Code Snippets

**Content-based cache key (Web):**
```javascript
// In frameHelpers.js
export function getContentKey(overlayId) {
  return overlayId;  // e.g., "talking_1_s_talking_1_e/7/J1_X2_M2.webp"
}

// In useVideoCanvasLogic.js - when caching
const key = frameData._cacheKey || frameData.overlay_id;
overlayFrameImagesRef.current.set(key, img);
```

**No skipFirstAdvance (Web):**
```javascript
// Web frontend has NO skipFirstAdvance logic
// The advanceOverlays() function simply advances every frame
const advanceOverlays = () => {
  overlayStatesRef.current.forEach((state, idx) => {
    if (!state.playing || state.done) return;
    state.currentDrawingFrame++;  // Always advance, no skip
    // ...
  });
};
```

**Per-frame animation name (Web):**
```javascript
// In drawHelpers.js - getOverlayDrivenBaseFrame()
const overlayFrame = section.frames[state.currentDrawingFrame];  // Current frame
const animName = overlayFrame.animation_name || currentBaseName; // This frame's name
```

**Decode readiness check (Web):**
```javascript
// In drawHelpers.js - isOverlayFrameReady()
export function isOverlayFrameReady(frameData, overlayFrameImagesRef) {
  const key = frameData._cacheKey || frameData.overlay_id;
  const img = overlayFrameImagesRef.get(key);
  // Check BOTH complete AND decoded
  return !!(img.complete && img.naturalWidth > 0 && img._decoded !== false);
}
```

**Skip frame if not ready (Web):**
```javascript
// In useVideoCanvasLogic.js draw loop
if (shouldStartPlaying) {
  if (!isOverlayFrameReady(overlayFrame, overlayFrameImagesRef.current)) {
    skipDrawThisFrame = true;  // Keep showing previous frame
  }
}
```
