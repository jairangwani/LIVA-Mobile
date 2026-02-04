# LIVA Animation SDK for Android

Native Android SDK for integrating LIVA avatar animations into any Android application.

## Requirements

- Android API 24+ (Android 7.0+)
- Android Studio Arctic Fox or later
- Kotlin 1.9+

## Installation

### Local Module (Development)

Add to your `settings.gradle.kts`:

```kotlin
include(":liva-animation")
project(":liva-animation").projectDir = file("../liva-sdk-android/liva-animation")
```

Add to your module's `build.gradle.kts`:

```kotlin
dependencies {
    implementation(project(":liva-animation"))
}
```

## Quick Start

```kotlin
import com.liva.animation.core.LIVAClient
import com.liva.animation.rendering.LIVACanvasView
import com.liva.animation.core.Configuration

class ChatActivity : AppCompatActivity() {
    private lateinit var livaCanvasView: LIVACanvasView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_chat)

        livaCanvasView = findViewById(R.id.livaCanvas)

        // Configure client
        val config = Configuration.LIVAConfiguration(
            serverUrl = "http://localhost:5003",  // use adb reverse for emulator
            userId = "user-123",
            agentId = "1"
        )

        // Connect and attach view
        LIVAClient.getInstance().configure(config)
        LIVAClient.getInstance().attachView(livaCanvasView)
        LIVAClient.getInstance().connect()
    }
}
```

## Architecture

```
liva-animation/
└── src/main/kotlin/com/liva/animation/
    ├── core/
    │   ├── LIVAClient.kt           # Main SDK interface
    │   ├── SocketManager.kt        # Socket.IO handling (Dyte library)
    │   └── Configuration.kt        # SDK configuration
    ├── rendering/
    │   ├── LIVACanvasView.kt       # SurfaceView rendering
    │   ├── AnimationEngine.kt      # Frame timing, state machine, audio-video sync
    │   ├── BaseFrameManager.kt     # Base frame cache
    │   └── FrameDecoder.kt         # Base64 → Bitmap decoding
    ├── audio/
    │   ├── AudioPlayer.kt          # MP3 playback (ExoPlayer)
    │   └── AudioSyncManager.kt     # Audio-video sync manager
    ├── logging/
    │   └── SessionLogger.kt        # Session-based logging to backend
    └── models/
        └── Models.kt               # Data classes (Frame, AnimationChunk, etc.)
```

## Key Features

- **Session logging** — Logs frames to backend, viewable at `http://localhost:5003/logs`
- **Async batch frame processing** — Prevents main thread blocking during overlay decoding
- **Buffer readiness** — Waits for 30+ decoded frames before starting playback
- **Skip-draw-on-wait** — Holds previous frame when overlay not yet decoded
- **Audio-video sync** — Audio triggers on first overlay frame render, not on receive
- **Progressive loading** — Loads idle animation first for instant startup

## API Reference

### LIVAClient

```kotlin
// Singleton instance
LIVAClient.getInstance()

// Configure SDK
fun configure(config: Configuration.LIVAConfiguration)

// Attach rendering view
fun attachView(view: LIVACanvasView)

// Connection
fun connect()
fun disconnect()
val isConnected: Boolean

// Callbacks
var onStateChange: ((LIVAState) -> Unit)?
var onError: ((LIVAError) -> Unit)?
```

### Configuration.LIVAConfiguration

```kotlin
data class LIVAConfiguration(
    val serverUrl: String,
    val userId: String,
    val agentId: String,
    val instanceId: String = "default",
    val resolution: String = "512"
)
```

## Emulator Networking

**Use `adb reverse`, NOT `10.0.2.2`** (unreliable on API 34):

```bash
# After emulator boots
adb reverse tcp:5003 tcp:5003

# Then use localhost in app code
val config = LIVAConfiguration(serverUrl = "http://localhost:5003", ...)
```

Cold boot the emulator when starting dev sessions — network stack can become corrupted with snapshots.

## Thread Safety

- All public APIs are thread-safe
- Callbacks are dispatched on the main thread
- Frame decoding happens on background threads

## Memory Management

The SDK automatically manages memory:
- Bitmap recycling via `inBitmap`
- LRU cache for frames (~100 frames)
- Automatic cleanup after playback

## ProGuard Rules

If using ProGuard/R8, add:

```proguard
-keep class com.liva.animation.** { *; }
-keep class io.socket.** { *; }
```

## Test App

See `liva-android-app/` for a native Android test app:

```bash
cd liva-android-app
./gradlew installDebug
```

## License

[License details]
