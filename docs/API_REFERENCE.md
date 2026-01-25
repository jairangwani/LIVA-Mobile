# SDK API Reference

Complete API reference for LIVA Animation SDKs.

## iOS SDK (Swift)

### LIVAClient

Main SDK interface.

```swift
// Singleton access
LIVAClient.shared

// Configuration
func configure(_ config: LIVAConfiguration)

// View attachment
func attachView(_ view: LIVACanvasView)

// Connection
func connect()
func disconnect()
var isConnected: Bool { get }

// State
var state: LIVAState { get }

// Callbacks
var onStateChange: ((LIVAState) -> Void)?
var onError: ((LIVAError) -> Void)?
```

### LIVAConfiguration

```swift
struct LIVAConfiguration {
    let serverURL: String      // Backend URL
    let userId: String         // User identifier
    let agentId: String        // Agent identifier
    var instanceId: String     // Session ID (default: "default")
    var resolution: String     // Canvas resolution (default: "512")
}
```

### LIVAState

```swift
enum LIVAState {
    case idle           // Not connected
    case connecting     // Connection in progress
    case connected      // Connected, waiting for animation
    case animating      // Avatar is speaking
    case error(LIVAError)
}
```

### LIVAError

```swift
enum LIVAError: Error {
    case notConfigured
    case connectionFailed(String)
    case socketDisconnected
    case frameDecodingFailed
    case audioPlaybackFailed
    case unknown(String)
}
```

### LIVACanvasView

```swift
class LIVACanvasView: UIView {
    // No public API - rendering is automatic
}
```

---

## Android SDK (Kotlin)

### LIVAClient

Main SDK interface.

```kotlin
// Singleton access
LIVAClient.getInstance()

// Configuration
fun configure(config: LIVAConfiguration)

// View attachment
fun attachView(view: LIVACanvasView)

// Connection
fun connect()
fun disconnect()
val isConnected: Boolean

// State
val state: LIVAState

// Callbacks
var onStateChange: ((LIVAState) -> Unit)?
var onError: ((LIVAError) -> Unit)?
```

### LIVAConfiguration

```kotlin
data class LIVAConfiguration(
    val serverUrl: String,         // Backend URL
    val userId: String,            // User identifier
    val agentId: String,           // Agent identifier
    val instanceId: String = "default",   // Session ID
    val resolution: String = "512"        // Canvas resolution
)
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

### LIVAError

```kotlin
sealed class LIVAError : Exception() {
    object NotConfigured : LIVAError()
    data class ConnectionFailed(val reason: String) : LIVAError()
    object SocketDisconnected : LIVAError()
    object FrameDecodingFailed : LIVAError()
    object AudioPlaybackFailed : LIVAError()
    data class Unknown(val message: String) : LIVAError()
}
```

### LIVACanvasView

```kotlin
class LIVACanvasView : SurfaceView {
    // No public API - rendering is automatic
}
```

---

## Flutter (Dart)

### LIVAAnimation

Platform channel interface.

```dart
// Initialize SDK
static Future<void> initialize({
  required String serverUrl,
  required String userId,
  required String agentId,
  String instanceId = 'default',
  String resolution = '512',
})

// Connection
static Future<void> connect()
static Future<void> disconnect()
static Future<bool> get isConnected

// State
static ValueNotifier<LIVAState> state

// Callbacks
static void Function(String error)? onError
```

### LIVAState

```dart
enum LIVAState {
  idle,
  connecting,
  connected,
  animating,
  error,
}
```

### LIVACanvasWidget

```dart
class LIVACanvasWidget extends StatelessWidget {
  // Renders native canvas view via platform view
}
```

---

## Common Usage Patterns

### Basic Integration

```swift
// iOS
let config = LIVAConfiguration(
    serverURL: "https://api.liva.com",
    userId: "user-123",
    agentId: "1"
)
LIVAClient.shared.configure(config)
LIVAClient.shared.attachView(canvasView)
LIVAClient.shared.connect()
```

```kotlin
// Android
val config = LIVAConfiguration(
    serverUrl = "https://api.liva.com",
    userId = "user-123",
    agentId = "1"
)
LIVAClient.getInstance().configure(config)
LIVAClient.getInstance().attachView(canvasView)
LIVAClient.getInstance().connect()
```

```dart
// Flutter
await LIVAAnimation.initialize(
  serverUrl: 'https://api.liva.com',
  userId: 'user-123',
  agentId: '1',
);
await LIVAAnimation.connect();
// Use LIVACanvasWidget() in your widget tree
```

### State Handling

```swift
// iOS
LIVAClient.shared.onStateChange = { state in
    switch state {
    case .idle: print("Idle")
    case .connecting: print("Connecting...")
    case .connected: print("Connected")
    case .animating: print("Speaking")
    case .error(let error): print("Error: \(error)")
    }
}
```

```kotlin
// Android
LIVAClient.getInstance().onStateChange = { state ->
    when (state) {
        is LIVAState.Idle -> println("Idle")
        is LIVAState.Connecting -> println("Connecting...")
        is LIVAState.Connected -> println("Connected")
        is LIVAState.Animating -> println("Speaking")
        is LIVAState.Error -> println("Error: ${state.error}")
    }
}
```

```dart
// Flutter
LIVAAnimation.state.addListener(() {
  final state = LIVAAnimation.state.value;
  print('State: $state');
});
```
