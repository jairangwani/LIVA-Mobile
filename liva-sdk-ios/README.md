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

## Memory Management

The SDK automatically manages memory:
- Frame cache limited to ~100 frames
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
