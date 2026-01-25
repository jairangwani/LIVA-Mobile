# LIVA SDK Integration Examples

This document shows how to integrate the LIVA Animation SDK into iOS and Android applications.

## iOS Integration (Swift)

### 1. Add the SDK

**Using Swift Package Manager:**
```swift
// In Xcode: File > Add Package Dependencies
// URL: https://github.com/your-org/liva-sdk-ios.git
```

**Using CocoaPods:**
```ruby
# Podfile
pod 'LIVAAnimation', '~> 1.0'
```

### 2. Basic Integration

```swift
import UIKit
import LIVAAnimation

class AvatarViewController: UIViewController {

    private var canvasView: LIVACanvasView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLIVA()
    }

    private func setupLIVA() {
        // 1. Configure the SDK
        let config = LIVAConfiguration(
            serverUrl: "https://your-backend.com",
            userId: "user-123",
            agentId: "1"
        )
        LIVAClient.shared.configure(config)

        // 2. Create and add the canvas view
        canvasView = LIVACanvasView(frame: view.bounds)
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvasView)

        // 3. Attach the view to the client
        LIVAClient.shared.attachView(canvasView)

        // 4. Set up callbacks
        LIVAClient.shared.onStateChange = { [weak self] state in
            self?.handleStateChange(state)
        }

        LIVAClient.shared.onError = { [weak self] error in
            self?.handleError(error)
        }

        // 5. Connect
        LIVAClient.shared.connect()
    }

    private func handleStateChange(_ state: LIVAState) {
        switch state {
        case .idle:
            print("Disconnected")
        case .connecting:
            print("Connecting...")
        case .connected:
            print("Connected - ready to chat")
        case .animating:
            print("Avatar is speaking")
        case .error(let error):
            print("Error: \(error)")
        }
    }

    private func handleError(_ error: LIVAError) {
        let alert = UIAlertController(
            title: "Error",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        LIVAClient.shared.disconnect()
    }
}
```

### 3. SwiftUI Integration

```swift
import SwiftUI
import LIVAAnimation

struct LIVACanvasRepresentable: UIViewRepresentable {
    @Binding var isConnected: Bool

    func makeUIView(context: Context) -> LIVACanvasView {
        let canvasView = LIVACanvasView(frame: .zero)

        // Configure on first creation
        let config = LIVAConfiguration(
            serverUrl: "https://your-backend.com",
            userId: "user-123",
            agentId: "1"
        )
        LIVAClient.shared.configure(config)
        LIVAClient.shared.attachView(canvasView)

        return canvasView
    }

    func updateUIView(_ uiView: LIVACanvasView, context: Context) {
        if isConnected && !LIVAClient.shared.isConnected {
            LIVAClient.shared.connect()
        } else if !isConnected && LIVAClient.shared.isConnected {
            LIVAClient.shared.disconnect()
        }
    }
}

struct AvatarView: View {
    @State private var isConnected = false

    var body: some View {
        VStack {
            LIVACanvasRepresentable(isConnected: $isConnected)
                .aspectRatio(1, contentMode: .fit)
                .background(Color.black)

            Button(isConnected ? "Disconnect" : "Connect") {
                isConnected.toggle()
            }
            .padding()
        }
    }
}
```

---

## Android Integration (Kotlin)

### 1. Add the SDK

**Using Gradle:**
```kotlin
// settings.gradle.kts
include(":liva-animation")
project(":liva-animation").projectDir = File("path/to/liva-sdk-android/liva-animation")

// app/build.gradle.kts
dependencies {
    implementation(project(":liva-animation"))
}
```

**Or from Maven (when published):**
```kotlin
dependencies {
    implementation("com.liva:animation:1.0.0")
}
```

### 2. Basic Integration

```kotlin
package com.example.myapp

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.liva.animation.core.LIVAClient
import com.liva.animation.core.LIVAConfiguration
import com.liva.animation.core.LIVAError
import com.liva.animation.core.LIVAState
import com.liva.animation.rendering.LIVACanvasView

class AvatarActivity : AppCompatActivity() {

    private lateinit var canvasView: LIVACanvasView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 1. Initialize the SDK with context
        LIVAClient.getInstance().initialize(applicationContext)

        // 2. Configure the SDK
        val config = LIVAConfiguration(
            serverUrl = "https://your-backend.com",
            userId = "user-123",
            agentId = "1"
        )
        LIVAClient.getInstance().configure(config)

        // 3. Create and set the canvas view
        canvasView = LIVACanvasView(this)
        setContentView(canvasView)

        // 4. Attach the view
        LIVAClient.getInstance().attachView(canvasView)

        // 5. Set up callbacks
        setupCallbacks()

        // 6. Connect
        LIVAClient.getInstance().connect()
    }

    private fun setupCallbacks() {
        LIVAClient.getInstance().onStateChange = { state ->
            runOnUiThread {
                handleStateChange(state)
            }
        }

        LIVAClient.getInstance().onError = { error ->
            runOnUiThread {
                handleError(error)
            }
        }
    }

    private fun handleStateChange(state: LIVAState) {
        when (state) {
            is LIVAState.Idle -> println("Disconnected")
            is LIVAState.Connecting -> println("Connecting...")
            is LIVAState.Connected -> println("Connected - ready to chat")
            is LIVAState.Animating -> println("Avatar is speaking")
            is LIVAState.Error -> println("Error: ${state.error}")
        }
    }

    private fun handleError(error: LIVAError) {
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Error")
            .setMessage(error.message ?: "Unknown error")
            .setPositiveButton("OK", null)
            .show()
    }

    override fun onDestroy() {
        super.onDestroy()
        LIVAClient.getInstance().disconnect()
    }

    override fun onLowMemory() {
        super.onLowMemory()
        LIVAClient.getInstance().onLowMemory()
    }
}
```

### 3. XML Layout Integration

```xml
<!-- res/layout/activity_avatar.xml -->
<?xml version="1.0" encoding="utf-8"?>
<FrameLayout
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@android:color/black">

    <com.liva.animation.rendering.LIVACanvasView
        android:id="@+id/canvas_view"
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        android:layout_gravity="center" />

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_gravity="bottom"
        android:orientation="vertical"
        android:padding="16dp"
        android:background="#80000000">

        <TextView
            android:id="@+id/status_text"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:textColor="@android:color/white"
            android:text="Disconnected" />

        <Button
            android:id="@+id/connect_button"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="Connect" />

    </LinearLayout>

</FrameLayout>
```

### 4. Jetpack Compose Integration

```kotlin
package com.example.myapp

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.liva.animation.core.LIVAClient
import com.liva.animation.core.LIVAConfiguration
import com.liva.animation.core.LIVAState
import com.liva.animation.rendering.LIVACanvasView

@Composable
fun LIVACanvasComposable(
    modifier: Modifier = Modifier,
    config: LIVAConfiguration
) {
    val context = LocalContext.current
    var connectionState by remember { mutableStateOf<LIVAState>(LIVAState.Idle) }

    DisposableEffect(config) {
        LIVAClient.getInstance().initialize(context)
        LIVAClient.getInstance().configure(config)

        LIVAClient.getInstance().onStateChange = { state ->
            connectionState = state
        }

        onDispose {
            LIVAClient.getInstance().disconnect()
        }
    }

    Column(modifier = modifier) {
        // Canvas View
        AndroidView(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .background(Color.Black),
            factory = { ctx ->
                LIVACanvasView(ctx).also { view ->
                    LIVAClient.getInstance().attachView(view)
                }
            }
        )

        // Status and Controls
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = when (connectionState) {
                    is LIVAState.Idle -> "Disconnected"
                    is LIVAState.Connecting -> "Connecting..."
                    is LIVAState.Connected -> "Connected"
                    is LIVAState.Animating -> "Speaking"
                    is LIVAState.Error -> "Error"
                }
            )

            Button(
                onClick = {
                    if (LIVAClient.getInstance().isConnected) {
                        LIVAClient.getInstance().disconnect()
                    } else {
                        LIVAClient.getInstance().connect()
                    }
                }
            ) {
                Text(if (LIVAClient.getInstance().isConnected) "Disconnect" else "Connect")
            }
        }
    }
}

// Usage
@Composable
fun AvatarScreen() {
    val config = remember {
        LIVAConfiguration(
            serverUrl = "https://your-backend.com",
            userId = "user-123",
            agentId = "1"
        )
    }

    LIVACanvasComposable(
        modifier = Modifier.fillMaxSize(),
        config = config
    )
}
```

---

## Sending Messages

Both SDKs connect via Socket.IO. To trigger avatar speech, send a message to your backend:

```swift
// iOS
func sendMessage(_ text: String) async throws {
    let url = URL(string: "https://your-backend.com/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "user_id": "user-123",
        "agent_id": "1",
        "instance_id": "default",
        "text": text
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (_, response) = try await URLSession.shared.data(for: request)
    // Response comes via Socket.IO as animation frames
}
```

```kotlin
// Android
suspend fun sendMessage(text: String) {
    val client = OkHttpClient()
    val json = JSONObject().apply {
        put("user_id", "user-123")
        put("agent_id", "1")
        put("instance_id", "default")
        put("text", text)
    }

    val request = Request.Builder()
        .url("https://your-backend.com/messages")
        .post(json.toString().toRequestBody("application/json".toMediaType()))
        .build()

    withContext(Dispatchers.IO) {
        client.newCall(request).execute()
        // Response comes via Socket.IO as animation frames
    }
}
```

---

## Debug Mode

Enable debug overlay to see FPS and frame count:

```swift
// iOS
canvasView.showDebugInfo = true
```

```kotlin
// Android
canvasView.showDebugInfo = true
```

---

## Memory Management

The SDKs handle memory automatically, but you can manually trigger cleanup:

```swift
// iOS - Called automatically on memory warning
LIVAClient.shared.handleMemoryWarning()
```

```kotlin
// Android - Call in onLowMemory()
LIVAClient.getInstance().onLowMemory()
```
