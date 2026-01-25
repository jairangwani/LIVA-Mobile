# Mobile Architecture

Detailed architecture for LIVA mobile SDKs and Flutter app.

## Overview

The mobile system consists of three components:

1. **Native SDKs** - Handle performance-critical rendering and socket communication
2. **Flutter App** - Provides UI/UX wrapper around native SDKs
3. **Backend** - Existing AnnaOS-API (no changes needed)

## Data Flow

```
User sends message
       │
       ▼
┌──────────────────┐
│  Flutter App     │
│  (Dart)          │
│                  │
│  POST /messages  │───────────────────────┐
└──────────────────┘                       │
                                           ▼
                                  ┌──────────────────┐
                                  │  AnnaOS-API      │
                                  │  (Python/Flask)  │
                                  │                  │
                                  │  • Process msg   │
                                  │  • Generate TTS  │
                                  │  • Get frames    │
                                  └────────┬─────────┘
                                           │
                              Socket.IO events
                                           │
       ┌───────────────────────────────────┘
       │
       ▼
┌──────────────────┐
│  Native SDK      │
│  (Swift/Kotlin)  │
│                  │
│  • receive_audio │
│  • receive_frame │
│  • Decode base64 │
│  • Render canvas │
│  • Play audio    │
└────────┬─────────┘
         │
    Platform Channel
         │
         ▼
┌──────────────────┐
│  Flutter App     │
│  (Dart)          │
│                  │
│  • Native View   │
│  • UI Controls   │
│  • State updates │
└──────────────────┘
         │
         ▼
    User sees animation
```

## Component Responsibilities

### Native SDKs (liva-sdk-ios / liva-sdk-android)

| Module | Responsibility |
|--------|----------------|
| **SocketManager** | Connect to backend, handle reconnection, manage rooms |
| **FrameDecoder** | Decode base64 WebP/PNG images to native bitmaps |
| **AnimationEngine** | Queue frames, manage timing (30fps talking, 10fps idle) |
| **CanvasView** | Native view that renders base + overlay frames |
| **AudioPlayer** | Decode MP3 chunks, play in sync with animation |
| **AudioSyncManager** | Coordinate audio playback with frame timing |

**Why Native?**
- Direct GPU access for canvas rendering
- No JS bridge overhead for frame decoding
- Predictable memory management
- Best battery efficiency

### Flutter App (liva-flutter-app)

| Module | Responsibility |
|--------|----------------|
| **Platform Channels** | Bridge to native SDKs |
| **Auth Feature** | Login, signup, guest user flows |
| **Chat Feature** | Message input, history display |
| **Agents Feature** | Agent selection, configuration |
| **Settings Feature** | User preferences, backend URL |

**Why Flutter?**
- Single codebase for iOS + Android UI
- Rich widget ecosystem
- Native SDK integration via platform channels
- Fast development iteration

## Socket.IO Events

### Connection Setup

```dart
// Flutter initiates connection via platform channel
LIVAAnimation.connect(
  url: 'https://api.liva.com',
  userId: 'user-uuid',
  agentId: '1',
  instanceId: 'default',
  resolution: '512',
);
```

### Server → Client Events

| Event | Data | SDK Action |
|-------|------|------------|
| `receive_audio` | Audio chunk + animation metadata | Queue audio, prepare frames |
| `receive_frame_images_batch` | 50 frames (base64 WebP) | Decode, cache in memory |
| `chunk_images_ready` | Chunk completion signal | Start playback if buffered |
| `audio_end` | No more audio | Transition to idle animation |
| `play_base_animation` | Animation name | Queue tail/idle sequence |

### Client → Server Events

| Event | Data | When |
|-------|------|------|
| Connection query | userId, agentId, resolution | On connect |
| `user_full_audio` | Audio blob (voice input) | Optional voice mode |

## Frame Rendering Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                    Frame Rendering (30fps)                   │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. receive_frame_images_batch arrives                      │
│     └─► Decode 50 base64 images → Bitmap array              │
│                                                              │
│  2. AnimationEngine queues frames                           │
│     └─► Frame timing based on master_frame_play_at          │
│                                                              │
│  3. CanvasView renders at 30fps                             │
│     ├─► Draw base frame (full avatar)                       │
│     └─► Draw overlay frame at zone_top_left position        │
│                                                              │
│  4. Audio plays in sync                                      │
│     └─► AudioSyncManager coordinates timing                 │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Memory Management

### iOS (Swift)
- Use `autoreleasepool` for batch image decoding
- Limit frame cache to ~100 frames (~50MB)
- Release frames after playback

### Android (Kotlin)
- Use `BitmapFactory.Options.inBitmap` for recycling
- Limit frame cache with LRU policy
- Release via `bitmap.recycle()`

### Target Metrics
| Metric | Target |
|--------|--------|
| Memory (idle) | < 50MB |
| Memory (animating) | < 150MB |
| Frame decode time | < 5ms per frame |
| Render time | < 16ms per frame (60fps capable) |

## Platform Channel API

### Flutter → Native

```dart
// Start animation view
LIVAAnimation.initialize(config);

// Connect to backend
LIVAAnimation.connect(url, userId, agentId);

// Disconnect
LIVAAnimation.disconnect();

// Get connection state
bool connected = await LIVAAnimation.isConnected();
```

### Native → Flutter

```dart
// Animation state changes
LIVAAnimation.onStateChange.listen((state) {
  // idle, connecting, connected, animating, error
});

// Errors
LIVAAnimation.onError.listen((error) {
  // Handle connection/playback errors
});
```

## Third-Party Integration

When other apps (ChatGPT, Claude, Gemini) integrate the SDK:

```swift
// iOS Integration Example
import LIVAAnimation

class ChatViewController: UIViewController {
    let livaView = LIVACanvasView()

    override func viewDidLoad() {
        view.addSubview(livaView)

        LIVAClient.shared.connect(
            url: "https://api.liva.com",
            userId: currentUser.id,
            agentId: "1"
        )

        LIVAClient.shared.attachView(livaView)
    }
}
```

```kotlin
// Android Integration Example
import com.liva.animation.LIVAClient
import com.liva.animation.LIVACanvasView

class ChatActivity : AppCompatActivity() {
    private lateinit var livaView: LIVACanvasView

    override fun onCreate(savedInstanceState: Bundle?) {
        livaView = findViewById(R.id.livaCanvas)

        LIVAClient.getInstance().connect(
            url = "https://api.liva.com",
            userId = currentUser.id,
            agentId = "1"
        )

        LIVAClient.getInstance().attachView(livaView)
    }
}
```

## Error Handling

| Error | SDK Response |
|-------|--------------|
| Socket disconnect | Auto-reconnect with exponential backoff (1s, 2s, 4s... max 30s) |
| Frame decode failure | Skip frame, log error, continue |
| Audio decode failure | Skip chunk, continue with animation |
| Memory pressure | Reduce frame cache, trigger GC |

## Testing Strategy

Tests are located in `LIVA-TESTS/mobile/`:

| Test Type | Location | Framework |
|-----------|----------|-----------|
| iOS SDK unit tests | `LIVA-TESTS/mobile/sdk-ios/` | XCTest |
| Android SDK unit tests | `LIVA-TESTS/mobile/sdk-android/` | JUnit |
| Flutter widget tests | `LIVA-TESTS/mobile/flutter/` | Flutter Test |
| E2E tests | `LIVA-TESTS/mobile/e2e/` | Patrol / Maestro |
