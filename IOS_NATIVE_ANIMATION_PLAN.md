# iOS Native Animation Implementation Plan

**Date:** 2026-01-26
**Goal:** Implement web animation system in iOS native SDK to match Interface app functionality

---

## Executive Summary

The web app (`AnnaOS-Interface`) uses a sophisticated animation system with:
- **Base animation frames** (idle, talking loops)
- **Overlay frames** (lip sync) synchronized with base frames
- **requestAnimationFrame** render loop at 30 FPS (overlay) / 10 FPS (idle)
- **Chunk-based streaming** from backend via Socket.IO
- **Adaptive buffering** to prevent playback stutter

This document maps the web architecture to iOS native implementation.

---

## 1. Architecture Comparison

### Web (React + JavaScript)

```javascript
// Animation state (useRef to avoid React re-renders)
const currentOverlayBaseNameRef = useRef("idle_1_s");
const modeRef = useRef("idle"); // idle, overlay, transition, finishingBase
const globalFrameIndexRef = useRef(0);

// Overlay management
const overlaySectionsRef = useRef([]); // Active overlay chunks
const overlayStatesRef = useRef([]);   // Playback state per section
const overlayQueueRef = useRef([]);    // Queued chunks waiting to play

// Image cache (Map for fast lookup)
const overlayFrameImagesRef = useRef(new Map()); // key: "chunk_section_frame"
const animationFramesRef = useRef({}); // Base frames by animation name

// Render loop (60 FPS browser, throttled to 30/10 FPS)
useEffect(() => {
  const draw = (now) => {
    // 1. Determine base frame to draw
    // 2. Draw base frame to canvas
    // 3. Draw overlay frames on top (if in overlay mode)
    // 4. Advance frame counters
    // 5. Cleanup finished overlays
    rafId = requestAnimationFrame(draw);
  };
  rafId = requestAnimationFrame(draw);
  return () => cancelAnimationFrame(rafId);
}, []);
```

### iOS (Swift + UIKit)

```swift
// Animation state (class properties - no React needed)
class LIVAAnimationEngine {
    private var currentOverlayBaseName: String = "idle_1_s"
    private var mode: AnimationMode = .idle // enum: idle, overlay, transition
    private var globalFrameIndex: Int = 0

    // Overlay management
    private var overlaySections: [OverlaySection] = []
    private var overlayStates: [OverlayState] = []
    private var overlayQueue: [QueuedOverlay] = []

    // Image cache (Dictionary for fast lookup)
    private var overlayFrameImages: [String: UIImage] = [:] // key: "chunk_section_frame"
    private var animationFrames: [String: [UIImage]] = [:] // Base frames by animation name

    // Render loop (CADisplayLink for 60 FPS, throttled to 30/10 FPS)
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    func startRendering() {
        displayLink = CADisplayLink(target: self, selector: #selector(draw))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func draw(link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = now - lastFrameTime

        // Throttle to 30 FPS (overlay) or 10 FPS (idle)
        let frameDuration = mode == .idle ? 0.1 : 0.0333
        guard elapsed >= frameDuration else { return }

        lastFrameTime = now

        // 1. Determine base frame to draw
        // 2. Draw base frame to canvas view
        // 3. Draw overlay frames on top (if in overlay mode)
        // 4. Advance frame counters
        // 5. Cleanup finished overlays
    }
}
```

**Key Difference:** iOS doesn't need React's `useRef` pattern - regular class properties work fine since we control rendering directly with CADisplayLink.

---

## 2. Core Data Structures

### OverlaySection (chunk of animation)

**Web:**
```javascript
{
  mode: "lips_data",
  frames: [
    {
      matched_sprite_frame_number: 42,  // Which base frame this overlay goes with
      sheet_filename: "talking_1_s_talking_1_e.png",
      coordinates: [x, y, width, height],
      image_data: ArrayBuffer,  // Binary image data
      sequence_index: 0,  // Position in chunk
      animation_name: "talking_1_s_talking_1_e"
    },
    // ... more frames
  ],
  sectionIndex: 0,
  chunkIndex: 0,
  zone_top_left: [x, y],
  uniqueSetId: 123,
  animation_total_frames: 216
}
```

**iOS:**
```swift
struct OverlaySection {
    let mode: String
    let frames: [OverlayFrame]
    let sectionIndex: Int
    let chunkIndex: Int
    let zoneTopLeft: CGPoint
    let uniqueSetId: Int
    let animationTotalFrames: Int
}

struct OverlayFrame {
    let matchedSpriteFrameNumber: Int  // Which base frame this overlay goes with
    let sheetFilename: String
    let coordinates: CGRect
    let imageData: Data  // Binary image data
    let sequenceIndex: Int
    let animationName: String
}
```

### OverlayState (playback state)

**Web:**
```javascript
{
  playing: false,
  currentDrawingFrame: 0,  // Current position in frames array
  done: false,
  audioStarted: false,
  skipFirstAdvance: true,  // Sync with base frame
  startTime: null
}
```

**iOS:**
```swift
struct OverlayState {
    var playing: Bool = false
    var currentDrawingFrame: Int = 0
    var done: Bool = false
    var audioStarted: Bool = false
    var skipFirstAdvance: Bool = true
    var startTime: CFTimeInterval?
}
```

---

## 3. Frame Synchronization Logic

**CRITICAL CONCEPT:** Overlay frames are synchronized with base frames via `matched_sprite_frame_number`.

### Web Implementation (useVideoCanvasLogic.js:926-997)

```javascript
// Get base frame requirement from overlay data
const overlayDrivenFrame = getOverlayDrivenBaseFrame(
    overlaySectionsRef.current,
    overlayStatesRef.current,
    overlayFrameImagesRef.current,
    animationFramesRef.current,
    expectedFrameCountsRef.current,
    currentOverlayBaseNameRef.current
);

if (overlayDrivenFrame) {
    // OVERLAY MODE: Use overlay's exact base frame requirement
    const { animationName, frameIndex, sectionIndex, shouldStartPlaying, chunkIndex } = overlayDrivenFrame;

    // Start overlay if ready
    if (shouldStartPlaying) {
        state.playing = true;
        state.currentDrawingFrame = 0;
        state.skipFirstAdvance = true;
        modeRef.current = "overlay";
    }

    // Switch base animation if needed
    if (animationName !== currentOverlayBaseNameRef.current) {
        currentOverlayBaseNameRef.current = animationName;
    }

    // Draw base frame at the index specified by overlay
    baseImageToDraw = baseFrames[frameIndex];
    globalFrameIndexRef.current = frameIndex;
} else {
    // IDLE MODE: No overlay, use independent frame counter
    baseImageToDraw = baseFrames[globalFrameIndexRef.current];
}
```

### iOS Implementation Plan

```swift
func getOverlayDrivenBaseFrame() -> OverlayDrivenFrame? {
    // Find first playing or ready-to-start overlay section
    for (index, section) in overlaySections.enumerated() {
        let state = overlayStates[index]

        // If already playing, use its current frame requirement
        if state.playing {
            let overlayFrame = section.frames[state.currentDrawingFrame]
            let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % getBaseFrameCount(section.animationName)

            return OverlayDrivenFrame(
                animationName: section.animationName,
                frameIndex: baseFrameIndex,
                sectionIndex: index,
                shouldStartPlaying: false,
                chunkIndex: section.chunkIndex
            )
        }

        // Check if ready to start (first frame decoded)
        if !state.playing && !state.done && isFirstOverlayFrameReady(section) {
            let overlayFrame = section.frames[0]
            let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % getBaseFrameCount(section.animationName)

            return OverlayDrivenFrame(
                animationName: section.animationName,
                frameIndex: baseFrameIndex,
                sectionIndex: index,
                shouldStartPlaying: true,  // Signal to start playing
                chunkIndex: section.chunkIndex
            )
        }
    }

    return nil // No overlay active, use idle mode
}

struct OverlayDrivenFrame {
    let animationName: String
    let frameIndex: Int
    let sectionIndex: Int
    let shouldStartPlaying: Bool
    let chunkIndex: Int
}
```

**Key Insight:** The overlay data contains `matched_sprite_frame_number` which tells us EXACTLY which base frame to display. We don't maintain an independent base frame counter in overlay mode - we let the overlay drive the base frame.

---

## 4. Rendering Pipeline

### Web Canvas Rendering (useVideoCanvasLogic.js:1000-1080)

```javascript
// Draw base frame (fills entire canvas)
ctx.clearRect(0, 0, canvas.width, canvas.height);
ctx.drawImage(baseImageToDraw, 0, 0, canvasSize.width, canvasSize.height);

// Draw overlays on top (if in overlay mode)
if (modeRef.current === "overlay") {
    overlaySectionsRef.current.forEach((section, idx) => {
        const state = overlayStatesRef.current[idx];
        if (state && state.playing) {
            const overlayFrame = section.frames[state.currentDrawingFrame];
            const overlayKey = getOverlayKey(section.chunkIndex, section.sectionIndex, state.currentDrawingFrame);
            const overlayImg = overlayFrameImagesRef.current.get(overlayKey);

            if (overlayImg && overlayImg.complete && overlayImg.naturalWidth > 0) {
                const [x, y, w, h] = overlayFrame.coordinates;
                ctx.drawImage(overlayImg, x, y, w, h);
            }
        }
    });
}
```

### iOS UIView Rendering

**Option 1: UIImageView Layer Composition (Recommended)**

```swift
class LIVACanvasView: UIView {
    private let baseImageView = UIImageView()
    private var overlayImageViews: [UIImageView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Base image view (bottom layer)
        baseImageView.frame = bounds
        baseImageView.contentMode = .scaleToFill
        addSubview(baseImageView)
    }

    func renderFrame(base: UIImage, overlays: [(image: UIImage, frame: CGRect)]) {
        // Update base image
        baseImageView.image = base

        // Clear old overlay views
        overlayImageViews.forEach { $0.removeFromSuperview() }
        overlayImageViews.removeAll()

        // Add new overlay views
        for (overlayImage, overlayFrame) in overlays {
            let overlayView = UIImageView(frame: overlayFrame)
            overlayView.image = overlayImage
            overlayView.contentMode = .scaleToFill
            addSubview(overlayView)
            overlayImageViews.append(overlayView)
        }
    }
}
```

**Option 2: Core Graphics Manual Compositing (More control)**

```swift
class LIVACanvasView: UIView {
    private var baseImage: UIImage?
    private var overlayImages: [(image: UIImage, frame: CGRect)] = []

    func renderFrame(base: UIImage, overlays: [(image: UIImage, frame: CGRect)]) {
        self.baseImage = base
        self.overlayImages = overlays
        setNeedsDisplay() // Trigger draw()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Clear canvas
        ctx.clear(rect)

        // Draw base image (fill entire view)
        if let baseImage = baseImage {
            baseImage.draw(in: bounds)
        }

        // Draw overlays on top
        for (overlayImage, overlayFrame) in overlayImages {
            overlayImage.draw(in: overlayFrame)
        }
    }
}
```

**Recommendation:** Use Option 1 (UIImageView composition) for better performance. UIKit will handle layer composition efficiently.

---

## 5. Frame Advancement Logic

### Web Implementation (useVideoCanvasLogic.js:1480-1530)

```javascript
const advanceOverlays = () => {
    overlaySectionsRef.current.forEach((section, idx) => {
        const state = overlayStatesRef.current[idx];
        if (!state.playing || state.done) return;

        // Skip first advance to sync with base frame
        if (state.skipFirstAdvance) {
            state.skipFirstAdvance = false;
            return;
        }

        // Advance overlay frame counter
        state.currentDrawingFrame++;

        if (state.currentDrawingFrame >= section.frames.length) {
            state.playing = false;
            state.done = true;
        }
    });
};
```

### iOS Implementation

```swift
func advanceOverlays() {
    for (index, section) in overlaySections.enumerated() {
        var state = overlayStates[index]

        guard state.playing && !state.done else { continue }

        // Skip first advance to sync with base frame
        if state.skipFirstAdvance {
            state.skipFirstAdvance = false
            overlayStates[index] = state
            continue
        }

        // Advance overlay frame counter
        state.currentDrawingFrame += 1

        if state.currentDrawingFrame >= section.frames.count {
            state.playing = false
            state.done = true
        }

        overlayStates[index] = state
    }
}
```

---

## 6. Cleanup & Memory Management

### Web Implementation (useVideoCanvasLogic.js:1604-1654)

```javascript
const cleanupOverlays = () => {
    // Filter out completed sections
    const active = overlaySectionsRef.current.filter((_, i) => !overlayStatesRef.current[i].done);

    if (active.length !== overlaySectionsRef.current.length) {
        const doneChunks = overlaySectionsRef.current.filter((_, i) => overlayStatesRef.current[i].done);
        const doneChunkIndices = new Set(doneChunks.map(s => s.chunkIndex));

        // Async cleanup of images for completed chunks
        scheduleAsyncImageCleanup(doneChunkIndices);

        // Update active sections
        overlaySectionsRef.current = active;
        overlayStatesRef.current = overlayStatesRef.current.filter(st => !st.done);

        if (active.length === 0) {
            isSetPlayingRef.current = false;

            // Start next chunk in queue (if any)
            if (overlayQueueRef.current.length > 0) {
                startNextOverlaySetIfAny();
            } else {
                // All chunks done, return to idle
                modeRef.current = "idle";
            }
        }
    }
};

// Proactive cleanup - evict images from completed chunks
const scheduleAsyncImageCleanup = (doneChunkIndices) => {
    setTimeout(() => {
        for (const chunkIndex of doneChunkIndices) {
            const keysToDelete = [];
            for (const [key, img] of overlayFrameImagesRef.current.entries()) {
                if (key.startsWith(`${chunkIndex}_`)) {
                    // Revoke blob URL to prevent memory leak
                    if (img._blobUrl) {
                        URL.revokeObjectURL(img._blobUrl);
                    }
                    keysToDelete.push(key);
                }
            }
            keysToDelete.forEach(key => overlayFrameImagesRef.current.delete(key));
        }
    }, 0);
};
```

### iOS Implementation

```swift
func cleanupOverlays() {
    // Filter out completed sections
    let activeSections = overlaySections.enumerated().filter { index, _ in
        !overlayStates[index].done
    }

    if activeSections.count != overlaySections.count {
        // Get completed chunk indices
        let doneChunkIndices = Set(
            overlaySections.enumerated()
                .filter { overlayStates[$0].done }
                .map { $1.chunkIndex }
        )

        // Async cleanup of images for completed chunks
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.cleanupImagesForChunks(doneChunkIndices)
        }

        // Update active sections
        overlaySections = activeSections.map { $1 }
        overlayStates = activeSections.map { overlayStates[$0] }

        if overlaySections.isEmpty {
            isSetPlaying = false

            // Start next chunk in queue (if any)
            if !overlayQueue.isEmpty {
                startNextOverlaySetIfAny()
            } else {
                // All chunks done, return to idle
                mode = .idle
            }
        }
    }
}

private func cleanupImagesForChunks(_ chunkIndices: Set<Int>) {
    for chunkIndex in chunkIndices {
        let keysToDelete = overlayFrameImages.keys.filter { key in
            key.hasPrefix("\(chunkIndex)_")
        }

        DispatchQueue.main.async { [weak self] in
            keysToDelete.forEach { self?.overlayFrameImages.removeValue(forKey: $0) }
        }
    }
}
```

---

## 7. Socket.IO Event Handlers

### Events from Backend

**Web implementation pattern:**

```javascript
// 1. Chunk metadata arrives
socket.on('animation_chunk_metadata', (data) => {
    // data = { chunk_index, total_frames, animation_name, first_frame_image }
    enqueueOverlaySet(data.frames, data.chunk_index, data.uniqueSetId, {
        total_frame_images: data.total_frames,
        first_frame_image: data.first_frame_image
    });
});

// 2. Individual frame images arrive
socket.on('receive_frame_image', (data) => {
    // data = { chunk_index, section_index, sequence_index, image_data, overlay_id }
    const frame = {
        image_data: data.image_data, // ArrayBuffer
        matched_sprite_frame_number: data.matched_sprite_frame_number,
        sheet_filename: data.sheet_filename,
        coordinates: data.coordinates,
        sequence_index: data.sequence_index
    };

    registerOverlayImageForFrame(frame, data.chunk_index, data.section_index, data.sequence_index);
});

// 3. Audio chunks arrive
socket.on('receive_audio', (data) => {
    // data = { audio_data, chunk_index }
    playAudioChunk(data.audio_data, data.chunk_index);
});
```

### iOS Socket.IO Handlers

```swift
// In SocketManager.swift - add new handlers

func setupAnimationEventHandlers() {
    // 1. Chunk metadata arrives
    socket?.on("animation_chunk_metadata") { [weak self] data, ack in
        guard let self = self,
              let dict = data[0] as? [String: Any],
              let chunkIndex = dict["chunk_index"] as? Int,
              let totalFrames = dict["total_frames"] as? Int,
              let animationName = dict["animation_name"] as? String,
              let frames = dict["frames"] as? [[String: Any]] else {
            return
        }

        // Parse frames and enqueue
        let overlayFrames = frames.compactMap { parseOverlayFrame($0) }
        animationEngine.enqueueOverlaySet(
            frames: overlayFrames,
            chunkIndex: chunkIndex,
            animationName: animationName,
            totalFrames: totalFrames
        )
    }

    // 2. Individual frame images arrive
    socket?.on("receive_frame_image") { [weak self] data, ack in
        guard let self = self,
              let dict = data[0] as? [String: Any],
              let chunkIndex = dict["chunk_index"] as? Int,
              let sectionIndex = dict["section_index"] as? Int,
              let sequenceIndex = dict["sequence_index"] as? Int,
              let imageData = dict["image_data"] as? Data else {
            return
        }

        // Decode image and cache it
        if let image = UIImage(data: imageData) {
            let key = "\(chunkIndex)_\(sectionIndex)_\(sequenceIndex)"
            animationEngine.cacheOverlayImage(image, forKey: key)
        }
    }

    // 3. Audio chunks arrive
    socket?.on("receive_audio") { [weak self] data, ack in
        guard let self = self,
              let dict = data[0] as? [String: Any],
              let audioData = dict["audio_data"] as? Data,
              let chunkIndex = dict["chunk_index"] as? Int else {
            return
        }

        audioPlayer.playChunk(audioData, chunkIndex: chunkIndex)
    }
}

private func parseOverlayFrame(_ dict: [String: Any]) -> OverlayFrame? {
    guard let matchedFrame = dict["matched_sprite_frame_number"] as? Int,
          let filename = dict["sheet_filename"] as? String,
          let coords = dict["coordinates"] as? [CGFloat],
          coords.count == 4,
          let seqIndex = dict["sequence_index"] as? Int,
          let animName = dict["animation_name"] as? String else {
        return nil
    }

    return OverlayFrame(
        matchedSpriteFrameNumber: matchedFrame,
        sheetFilename: filename,
        coordinates: CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3]),
        imageData: Data(), // Will be filled later via receive_frame_image
        sequenceIndex: seqIndex,
        animationName: animName
    )
}
```

---

## 8. Image Cache Management

### Web Implementation (useVideoCanvasLogic.js:212-260)

```javascript
const MAX_OVERLAY_IMAGE_CACHE_SIZE = 500;
const chunkImageKeysRef = useRef(new Map()); // Track which images belong to which chunk

const manageImageCache = (cache, key, img, chunkIndex) => {
    // Track this image as belonging to the chunk
    if (chunkIndex !== undefined) {
        if (!chunkImageKeysRef.current.has(chunkIndex)) {
            chunkImageKeysRef.current.set(chunkIndex, new Set());
        }
        chunkImageKeysRef.current.get(chunkIndex).add(key);
    }

    // If cache is full, evict entire completed chunks
    if (cache.size >= MAX_OVERLAY_IMAGE_CACHE_SIZE) {
        const activeChunkIndices = new Set(overlaySectionsRef.current.map(s => s.chunkIndex));

        // Evict entire completed chunks at once (most efficient)
        for (const [completedChunkIndex, imageKeys] of chunkImageKeysRef.current.entries()) {
            if (!activeChunkIndices.has(completedChunkIndex)) {
                imageKeys.forEach(evictKey => {
                    const evictedImg = cache.get(evictKey);
                    if (evictedImg && evictedImg._blobUrl) {
                        URL.revokeObjectURL(evictedImg._blobUrl);
                    }
                    cache.delete(evictKey);
                });
                chunkImageKeysRef.current.delete(completedChunkIndex);
                break;
            }
        }
    }

    cache.set(key, img);
};
```

### iOS Implementation (NSCache - Better Performance)

```swift
class LIVAImageCache {
    private let cache = NSCache<NSString, UIImage>()
    private var chunkImageKeys: [Int: Set<String>] = [:]

    init() {
        // Configure cache limits
        cache.countLimit = 500 // Max 500 images
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    func setImage(_ image: UIImage, forKey key: String, chunkIndex: Int) {
        // Track which images belong to which chunk
        if chunkImageKeys[chunkIndex] == nil {
            chunkImageKeys[chunkIndex] = Set()
        }
        chunkImageKeys[chunkIndex]?.insert(key)

        // Calculate cost (approximate memory size)
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func getImage(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }

    func evictChunks(_ chunkIndices: Set<Int>) {
        for chunkIndex in chunkIndices {
            guard let imageKeys = chunkImageKeys[chunkIndex] else { continue }

            for key in imageKeys {
                cache.removeObject(forKey: key as NSString)
            }

            chunkImageKeys.removeValue(forKey: chunkIndex)
        }
    }
}
```

**Key Advantage:** NSCache automatically evicts objects when memory pressure occurs, and calculates memory usage per image via `cost` parameter.

---

## 9. Complete iOS Animation Engine Structure

```swift
// MARK: - Animation Engine

class LIVAAnimationEngine {
    // MARK: - State
    private var currentOverlayBaseName: String = "idle_1_s"
    private var mode: AnimationMode = .idle
    private var globalFrameIndex: Int = 0

    // MARK: - Overlay Management
    private var overlaySections: [OverlaySection] = []
    private var overlayStates: [OverlayState] = []
    private var overlayQueue: [QueuedOverlay] = []
    private var isSetPlaying: Bool = false

    // MARK: - Image Cache
    private let imageCache = LIVAImageCache()
    private var animationFrames: [String: [UIImage]] = [:]

    // MARK: - Rendering
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private weak var canvasView: LIVACanvasView?

    // MARK: - Frame Rate Constants
    private let idleFrameRate: Double = 10.0
    private let activeFrameRate: Double = 30.0

    // MARK: - Initialization

    init(canvasView: LIVACanvasView) {
        self.canvasView = canvasView
    }

    // MARK: - Public API

    func startRendering() {
        displayLink = CADisplayLink(target: self, selector: #selector(draw))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopRendering() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func enqueueOverlaySet(frames: [OverlayFrame], chunkIndex: Int, animationName: String, totalFrames: Int) {
        let section = OverlaySection(
            mode: "lips_data",
            frames: frames,
            sectionIndex: 0,
            chunkIndex: chunkIndex,
            zoneTopLeft: .zero,
            uniqueSetId: chunkIndex,
            animationTotalFrames: totalFrames
        )

        let queued = QueuedOverlay(
            section: section,
            animationName: animationName
        )

        overlayQueue.append(queued)

        // Start playback if not already playing
        if !isSetPlaying {
            startNextOverlaySetIfAny()
        }
    }

    func cacheOverlayImage(_ image: UIImage, forKey key: String, chunkIndex: Int) {
        imageCache.setImage(image, forKey: key, chunkIndex: chunkIndex)
    }

    func loadBaseAnimation(name: String, frames: [UIImage]) {
        animationFrames[name] = frames
    }

    // MARK: - Rendering Loop

    @objc private func draw(link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = now - lastFrameTime

        // Throttle to 30 FPS (overlay) or 10 FPS (idle)
        let frameDuration = mode == .idle ? (1.0 / idleFrameRate) : (1.0 / activeFrameRate)
        guard elapsed >= frameDuration else { return }

        lastFrameTime = now

        // 1. Determine base frame to draw
        let baseImage: UIImage?
        if let overlayDriven = getOverlayDrivenBaseFrame() {
            // Overlay mode: use overlay's exact base frame requirement
            if overlayDriven.shouldStartPlaying {
                overlayStates[overlayDriven.sectionIndex].playing = true
                overlayStates[overlayDriven.sectionIndex].currentDrawingFrame = 0
                overlayStates[overlayDriven.sectionIndex].skipFirstAdvance = true
                mode = .overlay
            }

            if overlayDriven.animationName != currentOverlayBaseName {
                currentOverlayBaseName = overlayDriven.animationName
            }

            let baseFrames = animationFrames[currentOverlayBaseName] ?? []
            baseImage = baseFrames[safe: overlayDriven.frameIndex]
            globalFrameIndex = overlayDriven.frameIndex
        } else {
            // Idle mode: use independent frame counter
            let baseFrames = animationFrames[currentOverlayBaseName] ?? []
            baseImage = baseFrames[safe: globalFrameIndex]
        }

        // 2. Collect overlay images to draw
        var overlaysToRender: [(image: UIImage, frame: CGRect)] = []

        if mode == .overlay {
            for (index, section) in overlaySections.enumerated() {
                let state = overlayStates[index]

                guard state.playing else { continue }

                let overlayFrame = section.frames[state.currentDrawingFrame]
                let key = "\(section.chunkIndex)_\(section.sectionIndex)_\(state.currentDrawingFrame)"

                if let overlayImage = imageCache.getImage(forKey: key) {
                    overlaysToRender.append((overlayImage, overlayFrame.coordinates))
                }
            }
        }

        // 3. Render frame to canvas
        if let baseImage = baseImage {
            canvasView?.renderFrame(base: baseImage, overlays: overlaysToRender)
        }

        // 4. Advance frame counters
        if mode == .overlay {
            advanceOverlays()
            cleanupOverlays()
        } else if mode == .idle {
            advanceIdleFrame()
        }
    }

    // MARK: - Private Helpers

    private func getOverlayDrivenBaseFrame() -> OverlayDrivenFrame? {
        for (index, section) in overlaySections.enumerated() {
            let state = overlayStates[index]

            if state.playing {
                let overlayFrame = section.frames[state.currentDrawingFrame]
                let baseFrameCount = animationFrames[section.frames[0].animationName]?.count ?? 1
                let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount

                return OverlayDrivenFrame(
                    animationName: section.frames[0].animationName,
                    frameIndex: baseFrameIndex,
                    sectionIndex: index,
                    shouldStartPlaying: false,
                    chunkIndex: section.chunkIndex
                )
            }

            if !state.playing && !state.done && isFirstOverlayFrameReady(section) {
                let overlayFrame = section.frames[0]
                let baseFrameCount = animationFrames[section.frames[0].animationName]?.count ?? 1
                let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount

                return OverlayDrivenFrame(
                    animationName: section.frames[0].animationName,
                    frameIndex: baseFrameIndex,
                    sectionIndex: index,
                    shouldStartPlaying: true,
                    chunkIndex: section.chunkIndex
                )
            }
        }

        return nil
    }

    private func isFirstOverlayFrameReady(_ section: OverlaySection) -> Bool {
        let key = "\(section.chunkIndex)_\(section.sectionIndex)_0"
        return imageCache.getImage(forKey: key) != nil
    }

    private func advanceOverlays() {
        for (index, section) in overlaySections.enumerated() {
            var state = overlayStates[index]

            guard state.playing && !state.done else { continue }

            if state.skipFirstAdvance {
                state.skipFirstAdvance = false
                overlayStates[index] = state
                continue
            }

            state.currentDrawingFrame += 1

            if state.currentDrawingFrame >= section.frames.count {
                state.playing = false
                state.done = true
            }

            overlayStates[index] = state
        }
    }

    private func cleanupOverlays() {
        let activeSections = overlaySections.enumerated().filter { index, _ in
            !overlayStates[index].done
        }

        if activeSections.count != overlaySections.count {
            let doneChunkIndices = Set(
                overlaySections.enumerated()
                    .filter { overlayStates[$0].done }
                    .map { $1.chunkIndex }
            )

            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.imageCache.evictChunks(doneChunkIndices)
            }

            overlaySections = activeSections.map { $1 }
            overlayStates = activeSections.map { overlayStates[$0] }

            if overlaySections.isEmpty {
                isSetPlaying = false

                if !overlayQueue.isEmpty {
                    startNextOverlaySetIfAny()
                } else {
                    mode = .idle
                }
            }
        }
    }

    private func advanceIdleFrame() {
        let baseFrames = animationFrames[currentOverlayBaseName] ?? []
        guard !baseFrames.isEmpty else { return }

        globalFrameIndex = (globalFrameIndex + 1) % baseFrames.count
    }

    private func startNextOverlaySetIfAny() {
        guard !isSetPlaying && !overlayQueue.isEmpty else { return }

        let queued = overlayQueue.removeFirst()

        let state = OverlayState(
            playing: false,
            currentDrawingFrame: 0,
            done: false,
            audioStarted: false,
            skipFirstAdvance: true,
            startTime: nil
        )

        overlaySections = [queued.section]
        overlayStates = [state]
        isSetPlaying = true
    }
}

// MARK: - Supporting Types

enum AnimationMode {
    case idle
    case overlay
    case transition
}

struct QueuedOverlay {
    let section: OverlaySection
    let animationName: String
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
```

---

## 10. Integration with Existing iOS SDK

### Current SDK Architecture

```
LIVAClient (Singleton)
    └── SocketManager (Socket.IO connection)
    └── FrameDecoder (Base64 decoding - DEPRECATED)
    └── AnimationEngine (Old frame queue - REPLACE)
    └── LIVACanvasView (UIView rendering)
    └── AudioPlayer (MP3 streaming)
```

### New Architecture

```
LIVAClient (Singleton)
    └── SocketManager (Socket.IO connection - ADD HANDLERS)
    └── LIVAAnimationEngine (NEW - Base + Overlay rendering)
    │       └── LIVAImageCache (NEW - NSCache management)
    └── LIVACanvasView (UIView rendering - UPDATE)
    └── AudioPlayer (MP3 streaming - SYNC WITH CHUNKS)
```

### Migration Steps

1. **Add new animation engine** (`LIVAAnimationEngine.swift`)
2. **Update SocketManager** to handle new events:
   - `animation_chunk_metadata`
   - `receive_frame_image`
3. **Update LIVACanvasView** to support base + overlay rendering
4. **Replace old AnimationEngine** with new LIVAAnimationEngine
5. **Test with localhost backend**

---

## 11. Testing Strategy

### Phase 1: Base Frame Rendering
- Load idle animation frames
- Render at 10 FPS
- Verify smooth playback

### Phase 2: Overlay Frame Synchronization
- Receive chunk metadata from backend
- Cache overlay images as they arrive
- Synchronize overlay with base using `matched_sprite_frame_number`
- Verify overlay plays on correct base frames

### Phase 3: Multi-Chunk Streaming
- Queue multiple chunks
- Verify smooth transitions between chunks
- Test memory cleanup (old chunks evicted)

### Phase 4: Audio Sync
- Play audio chunks aligned with animation chunks
- Verify lip sync accuracy

---

## 12. Next Steps

1. **Review this plan** - Confirm architecture matches requirements
2. **Create LIVAAnimationEngine.swift** - Implement core engine
3. **Update SocketManager** - Add chunk streaming handlers
4. **Update LIVACanvasView** - Support base + overlay rendering
5. **Test with localhost backend** - Verify end-to-end flow
6. **Document iOS-specific patterns** - For future SDK users

---

## Key Differences from Web

| Aspect | Web (React) | iOS (Swift) |
|--------|-------------|-------------|
| Render Loop | requestAnimationFrame | CADisplayLink |
| State Management | useRef (avoid re-renders) | Class properties |
| Image Cache | Map with manual eviction | NSCache (auto eviction) |
| Canvas Rendering | HTML5 Canvas 2D API | UIView + Core Graphics |
| Async Operations | setTimeout/Promise | DispatchQueue |
| Binary Data | ArrayBuffer | Data |
| Image Loading | Image() with blob URLs | UIImage(data:) |

---

**Next Action:** Implement `LIVAAnimationEngine.swift` based on this architecture plan.
