# iOS Integration Guide

Step-by-step guide for integrating LIVA Animation SDK into your iOS app.

## Prerequisites

- Xcode 15.0+
- iOS deployment target 15.0+
- Backend server running (AnnaOS-API)

## Step 1: Install SDK

### Option A: Swift Package Manager

1. Open your project in Xcode
2. File → Add Packages
3. Enter: `https://github.com/liva/liva-sdk-ios.git`
4. Select version and add to your target

### Option B: CocoaPods

```ruby
# Podfile
target 'YourApp' do
  use_frameworks!
  pod 'LIVAAnimation', '~> 1.0'
end
```

```bash
pod install
```

## Step 2: Add Permissions

Add to `Info.plist` if using voice input:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>LIVA needs microphone access for voice input</string>
```

## Step 3: Initialize SDK

```swift
import LIVAAnimation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Configure once at app launch
        let config = LIVAConfiguration(
            serverURL: "https://api.liva.com",
            userId: getCurrentUserId(),
            agentId: "1"
        )

        LIVAClient.shared.configure(config)

        return true
    }
}
```

## Step 4: Add Canvas View

### Using Storyboard

1. Add a `UIView` to your view controller
2. Set custom class to `LIVACanvasView`
3. Connect as `@IBOutlet`

```swift
import LIVAAnimation

class ChatViewController: UIViewController {
    @IBOutlet weak var livaCanvasView: LIVACanvasView!

    override func viewDidLoad() {
        super.viewDidLoad()
        LIVAClient.shared.attachView(livaCanvasView)
    }
}
```

### Programmatically

```swift
import LIVAAnimation

class ChatViewController: UIViewController {
    private let livaCanvasView = LIVACanvasView()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Add to view hierarchy
        view.addSubview(livaCanvasView)

        // Layout (using Auto Layout)
        livaCanvasView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            livaCanvasView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            livaCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            livaCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            livaCanvasView.heightAnchor.constraint(equalTo: livaCanvasView.widthAnchor) // Square
        ])

        // Attach to client
        LIVAClient.shared.attachView(livaCanvasView)
    }
}
```

## Step 5: Handle Connection Lifecycle

```swift
class ChatViewController: UIViewController {

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        LIVAClient.shared.connect()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Optional: disconnect when leaving screen
        // LIVAClient.shared.disconnect()
    }
}
```

## Step 6: Handle State Changes

```swift
override func viewDidLoad() {
    super.viewDidLoad()

    LIVAClient.shared.onStateChange = { [weak self] state in
        switch state {
        case .idle:
            self?.statusLabel.text = "Ready"
        case .connecting:
            self?.statusLabel.text = "Connecting..."
        case .connected:
            self?.statusLabel.text = "Connected"
        case .animating:
            self?.statusLabel.text = "Speaking..."
        case .error(let error):
            self?.showError(error)
        }
    }

    LIVAClient.shared.onError = { [weak self] error in
        self?.showError(error)
    }
}
```

## Step 7: Send Messages

Messages trigger avatar animations via the backend:

```swift
func sendMessage(_ text: String) {
    // POST to your backend
    let url = URL(string: "https://api.liva.com/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userId, forHTTPHeaderField: "X-User-ID")

    let body: [String: Any] = [
        "AgentID": agentId,
        "message": text,
        "instance_id": "default"
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    URLSession.shared.dataTask(with: request) { data, response, error in
        // Animation frames arrive via Socket.IO automatically
    }.resume()
}
```

## SwiftUI Integration

```swift
import SwiftUI
import LIVAAnimation

struct LIVACanvasRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> LIVACanvasView {
        let view = LIVACanvasView()
        LIVAClient.shared.attachView(view)
        return view
    }

    func updateUIView(_ uiView: LIVACanvasView, context: Context) {
        // No updates needed
    }
}

struct ChatView: View {
    var body: some View {
        VStack {
            LIVACanvasRepresentable()
                .aspectRatio(1, contentMode: .fit)

            // Your chat UI below
            ChatInputView()
        }
        .onAppear {
            LIVAClient.shared.connect()
        }
    }
}
```

## Advanced: Custom Configuration

```swift
var config = LIVAConfiguration(
    serverURL: "https://api.liva.com",
    userId: "user-123",
    agentId: "1"
)

// Custom settings
config.instanceId = "chat-session-456"
config.resolution = "1024"  // Higher resolution frames

LIVAClient.shared.configure(config)
```

## Advanced: Multiple Agents

```swift
// Switch agent
func switchAgent(to agentId: String) {
    LIVAClient.shared.disconnect()

    var config = LIVAClient.shared.configuration
    config.agentId = agentId

    LIVAClient.shared.configure(config)
    LIVAClient.shared.connect()
}
```

## Troubleshooting

### SDK not animating
1. Check connection state: `LIVAClient.shared.isConnected`
2. Verify backend is returning frames
3. Check `onError` callback for issues

### Memory issues
The SDK auto-manages memory. If still an issue:
- Reduce resolution: `config.resolution = "256"`
- Ensure you're not retaining frame data

### Connection drops
SDK auto-reconnects. For custom handling:
```swift
LIVAClient.shared.onError = { error in
    if case .socketDisconnected = error {
        // Custom reconnection logic if needed
    }
}
```
