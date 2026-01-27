# LIVA Animation SDK for iOS

Native iOS SDK for integrating LIVA avatar animations into any iOS application.

## Requirements

- iOS 15.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

### Swift Package Manager (Recommended)

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/liva/liva-sdk-ios.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Packages → Enter repository URL.

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'LIVAAnimation', '~> 1.0'
```

Then run:

```bash
pod install
```

## Quick Start

```swift
import LIVAAnimation

class ViewController: UIViewController {
    private let livaView = LIVACanvasView()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Add canvas view
        view.addSubview(livaView)
        livaView.frame = view.bounds

        // Configure client
        let config = LIVAConfiguration(
            serverURL: "https://api.liva.com",
            userId: "user-123",
            agentId: "1"
        )

        // Connect and attach view
        LIVAClient.shared.configure(config)
        LIVAClient.shared.attachView(livaView)
        LIVAClient.shared.connect()
    }
}
```

## Architecture

```
LIVAAnimation/
├── Sources/
│   ├── Core/
│   │   ├── LIVAClient.swift        # Main SDK interface
│   │   ├── SocketManager.swift     # Socket.IO handling
│   │   └── Configuration.swift     # SDK configuration
│   ├── Rendering/
│   │   ├── CanvasView.swift        # Native canvas view
│   │   ├── FrameDecoder.swift      # Base64 → UIImage
│   │   └── AnimationEngine.swift   # Frame timing & queue
│   ├── Audio/
│   │   ├── AudioPlayer.swift       # MP3 playback
│   │   └── AudioSyncManager.swift  # Audio-video sync
│   └── Models/
│       ├── Frame.swift             # Frame data model
│       ├── AnimationChunk.swift    # Chunk metadata
│       └── AgentConfig.swift       # Agent configuration
└── Resources/
```

## API Reference

### LIVAClient

```swift
// Singleton instance
LIVAClient.shared

// Configure SDK
func configure(_ config: LIVAConfiguration)

// Attach rendering view
func attachView(_ view: LIVACanvasView)

// Connection
func connect()
func disconnect()
var isConnected: Bool { get }

// Callbacks
var onStateChange: ((LIVAState) -> Void)?
var onError: ((LIVAError) -> Void)?
```

### LIVAConfiguration

```swift
struct LIVAConfiguration {
    let serverURL: String
    let userId: String
    let agentId: String
    var instanceId: String = "default"
    var resolution: String = "512"
}
```

### LIVACanvasView

```swift
class LIVACanvasView: UIView {
    // Rendering happens automatically when attached to LIVAClient
}
```

### LIVAState

```swift
enum LIVAState {
    case idle
    case connecting
    case connected
    case animating
    case error(LIVAError)
}
```

## Thread Safety

- All public APIs are thread-safe
- Callbacks are dispatched on the main thread
- Frame decoding happens on background queues

## Performance

The SDK uses async frame processing to maintain 30fps animation:

- **Frame processing:** Batched with main thread yields (15 frames/batch)
- **Decode tracking:** Images marked ready only after full decode
- **Skip-draw-on-wait:** Holds previous frame if overlay not decoded

**Measured Performance (2026-01-27):**
- 33.3ms average frame delta (30fps)
- 98.5% frames within 28-40ms target range
- Zero freezes on cold start
- Chunk transitions: 74-213ms (improved from 100-300ms)

## Memory Management

The SDK automatically manages memory:
- Base animations: ~50-100 MB (depends on agent)
- Overlay cache: ~200 MB (2000 images max)
- Peak usage: ~250-300 MB during playback
- Automatic cleanup after playback
- Responds to memory warnings

## Example Project

See `Example/LIVADemo` for a complete integration example.

```bash
cd Example/LIVADemo
open LIVADemo.xcodeproj
```

## Troubleshooting

### Connection Issues

```swift
LIVAClient.shared.onError = { error in
    switch error {
    case .connectionFailed(let reason):
        print("Connection failed: \(reason)")
    case .socketDisconnected:
        print("Socket disconnected, will auto-reconnect")
    default:
        print("Error: \(error)")
    }
}
```

### Memory Warnings

The SDK automatically reduces cache on memory pressure. No action needed.

## License

[License details]
