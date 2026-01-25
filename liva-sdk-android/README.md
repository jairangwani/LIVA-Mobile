# LIVA Animation SDK for Android

Native Android SDK for integrating LIVA avatar animations into any Android application.

## Requirements

- Android API 24+ (Android 7.0+)
- Android Studio Arctic Fox or later
- Kotlin 1.9+

## Installation

### Gradle (Recommended)

Add to your module's `build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.liva:animation:1.0.0")
}
```

Add repository if not using Maven Central:

```kotlin
repositories {
    maven { url = uri("https://jitpack.io") }
}
```

### Manual AAR

1. Download `liva-animation.aar` from releases
2. Add to `libs/` folder
3. Add dependency:

```kotlin
dependencies {
    implementation(files("libs/liva-animation.aar"))
}
```

## Quick Start

```kotlin
import com.liva.animation.LIVAClient
import com.liva.animation.LIVACanvasView
import com.liva.animation.LIVAConfiguration

class ChatActivity : AppCompatActivity() {
    private lateinit var livaCanvasView: LIVACanvasView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_chat)

        livaCanvasView = findViewById(R.id.livaCanvas)

        // Configure client
        val config = LIVAConfiguration(
            serverUrl = "https://api.liva.com",
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
├── src/main/kotlin/com/liva/animation/
│   ├── core/
│   │   ├── LIVAClient.kt         # Main SDK interface
│   │   ├── SocketManager.kt      # Socket.IO handling
│   │   └── Configuration.kt      # SDK configuration
│   ├── rendering/
│   │   ├── CanvasView.kt         # Native canvas view
│   │   ├── FrameDecoder.kt       # Base64 → Bitmap
│   │   └── AnimationEngine.kt    # Frame timing & queue
│   ├── audio/
│   │   ├── AudioPlayer.kt        # MP3 playback
│   │   └── AudioSyncManager.kt   # Audio-video sync
│   └── models/
│       ├── Frame.kt              # Frame data model
│       ├── AnimationChunk.kt     # Chunk metadata
│       └── AgentConfig.kt        # Agent configuration
└── src/main/AndroidManifest.xml
```

## API Reference

### LIVAClient

```kotlin
// Singleton instance
LIVAClient.getInstance()

// Configure SDK
fun configure(config: LIVAConfiguration)

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

### LIVAConfiguration

```kotlin
data class LIVAConfiguration(
    val serverUrl: String,
    val userId: String,
    val agentId: String,
    val instanceId: String = "default",
    val resolution: String = "512"
)
```

### LIVACanvasView

```kotlin
class LIVACanvasView : SurfaceView {
    // Rendering happens automatically when attached to LIVAClient
}
```

### LIVAState

```kotlin
sealed class LIVAState {
    object Idle : LIVAState()
    object Connecting : LIVAState()
    object Connected : LIVAState()
    object Animating : LIVAState()
    data class Error(val error: LIVAError) : LIVAState()
}
```

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

## Example Project

See `example/` for a complete integration example.

```bash
cd example
./gradlew installDebug
```

## License

[License details]
