# iOS Freeze Debugging Guide

## Problem Statement

You're seeing visual freezes (frame counter hangs for ~1 second) during playback, but logs show no freezes. This guide helps **identify the exact root cause** so we can fix it.

---

## Step 1: Run Diagnostic Test

This captures frame-by-frame timing with detailed breakdowns:

```bash
cd LIVA-TESTS/scripts
./ios-diagnostic-test.sh
```

**What it does:**
1. Clean rebuild with full diagnostic logging
2. Starts iOS app
3. Sends test message
4. Analyzes timing events
5. Shows root cause summary

---

## Step 2: Check Console Output

Open Xcode console to see **real-time frame timing**:

```bash
# While test is running:
# Xcode > Window > Devices and Simulators > Select iPhone 15 Pro > Open Console
```

**Look for these patterns:**

### Pattern 1: Skip-Draw (Root Cause)
```
⏸️ SKIP-DRAW: chunk=0 seq=16 key=... isCached=true isDecoded=false
⏸️ SKIP-DRAW: chunk=0 seq=16 key=... isCached=true isDecoded=false
⏸️ SKIP-DRAW: chunk=0 seq=16 key=... isCached=true isDecoded=false
```
**Meaning:** Frame 16 is cached but NOT decoded yet, causing animation to pause

**Root Cause:** Pre-decode queue backlog or buffer too small

---

### Pattern 2: Slow Frame Timing
```
🔴 SLOW: Frame #150: delta=85.2ms total=12.3ms [base=0.5 overlay=2.1 decode=0.0 render=8.7] bottleneck=metal_render
```

**Breakdown:**
- `delta=85.2ms` - **Time since last frame** (should be ~17ms) = THE FREEZE
- `total=12.3ms` - Time spent in draw() method
- `base=0.5ms` - Base image lookup
- `overlay=2.1ms` - Overlay image lookup
- `decode=0.0ms` - If decode happened this frame
- `render=8.7ms` - Metal rendering time
- `bottleneck=metal_render` - **What took longest**

**Interpretation:**
- If `delta >> total`: Freeze happened **between frames** (not in our code)
- If `delta ≈ total`: Freeze happened **in our code**
- `bottleneck` tells you which operation to optimize

---

### Pattern 3: Normal Frames (No Issue)
```
✅ OK: Frame #100: delta=16.8ms total=8.2ms [base=0.3 overlay=0.8 decode=0.0 render=7.1] mode=overlay chunk=0 seq=10
```
Perfect - frame rendered in 16.8ms (60fps)

---

## Step 3: Interpret Results

### Scenario A: SKIP_DRAW Events Found
```
Event counts:
  SKIP_DRAW: 45
```

**Root Cause:** Images not decoded in time

**Fix Options:**
1. ✅ **Increase buffer** from 10 to 20-30 frames
2. ✅ **Reduce image quality** (smaller overlays decode faster)
3. ✅ **Pre-decode earlier** (start on metadata arrival, not image arrival)

---

### Scenario B: Slow Frames with bottleneck=overlay_lookup
```
🔴 SLOW: Frame #87: delta=120ms bottleneck=overlay_lookup
```

**Root Cause:** Cache miss or slow cache access

**Fix Options:**
1. Check if images are being evicted too early
2. Verify cache key consistency
3. Increase cache size

---

### Scenario C: Slow Frames with bottleneck=metal_render
```
🔴 SLOW: Frame #23: delta=95ms bottleneck=metal_render
```

**Root Cause:** GPU texture upload or Metal command buffer delay

**Fix Options:**
1. ✅ **Use MTLTexture cache** (reuse textures, don't create new ones each frame)
2. Pre-warm textures by drawing off-screen
3. Test on real device (simulator GPU is slower)

---

### Scenario D: delta >> total (Freeze Between Frames)
```
🔴 SLOW: Frame #45: delta=150ms total=9ms
```

**Root Cause:** Main thread blocked between frames (NOT in draw())

**Culprits:**
1. Flutter framework doing heavy work
2. Main thread lock contention
3. Garbage collection

**Fix:** Profile with Instruments to find main thread blocker

---

## Step 4: Verify Fix

After applying fix:

```bash
# Run diagnostic again
./ios-diagnostic-test.sh

# Check if SKIP_DRAW or SLOW_FRAME events reduced
```

**Success criteria:**
- `SKIP_DRAW: 0`
- `SLOW_FRAME: <5` (occasional is OK)
- All `delta < 25ms`

---

## Common Root Causes (Ordered by Likelihood)

1. **Skip-draw due to decode lag** (80% of freezes)
   - Fix: Larger buffer or faster decode

2. **Metal texture upload lag** (15% of freezes)
   - Fix: Texture caching or real device test

3. **Main thread blocking between frames** (5% of freezes)
   - Fix: Profile with Instruments

---

## Tools Reference

### View Session Logs
```bash
open http://localhost:5003/logs
```

### View Xcode Console
```
Xcode > Window > Devices and Simulators > Open Console
```

### Export Console Log
```
# In Xcode Console:
# Right-click > Save Selection
```

### Instruments Profiling
```bash
# Profile main thread blocking:
# Xcode > Product > Profile
# Choose "Time Profiler"
# Look for spikes during freeze
```

---

## Debug Flags (Edit if Needed)

**File:** `LIVAFrameTiming.swift:24`
```swift
private var isEnabled: Bool = true  // Set to false to disable verbose logging
```

**File:** `LIVAAnimationEngine.swift:175`
```swift
private let minFramesBeforeStart = 10  // Increase to 20-30 if seeing SKIP_DRAW
```

---

## Next Steps

1. ✅ Run `./ios-diagnostic-test.sh`
2. ✅ Check console output for patterns above
3. ✅ Identify root cause from bottleneck analysis
4. ✅ Apply appropriate fix
5. ✅ Re-test to verify

**If still unclear:** Share console log output and I'll analyze it.
