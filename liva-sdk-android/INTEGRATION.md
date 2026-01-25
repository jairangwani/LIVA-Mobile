# Android Integration Guide

Step-by-step guide for integrating LIVA Animation SDK into your Android app.

## Prerequisites

- Android Studio Arctic Fox+
- minSdk 24 (Android 7.0+)
- Backend server running (AnnaOS-API)

## Step 1: Install SDK

### Option A: Gradle

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("com.liva:animation:1.0.0")
}
```

### Option B: Local AAR

```kotlin
dependencies {
    implementation(files("libs/liva-animation.aar"))
}
```

## Step 2: Add Permissions

Add to `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />

<!-- Optional: for voice input -->
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

## Step 3: Add Canvas View to Layout

```xml
<!-- activity_chat.xml -->
<FrameLayout
    android:layout_width="match_parent"
    android:layout_height="match_parent">

    <com.liva.animation.LIVACanvasView
        android:id="@+id/livaCanvas"
        android:layout_width="match_parent"
        android:layout_height="match_parent" />

    <!-- Your chat UI -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_gravity="bottom">
        <!-- Input field, send button, etc. -->
    </LinearLayout>

</FrameLayout>
```

## Step 4: Initialize SDK

```kotlin
import com.liva.animation.LIVAClient
import com.liva.animation.LIVAConfiguration

class MyApplication : Application() {
    override fun onCreate() {
        super.onCreate()

        val config = LIVAConfiguration(
            serverUrl = "https://api.liva.com",
            userId = getCurrentUserId(),
            agentId = "1"
        )

        LIVAClient.getInstance().configure(config)
    }
}
```

## Step 5: Attach View and Connect

```kotlin
class ChatActivity : AppCompatActivity() {
    private lateinit var livaCanvasView: LIVACanvasView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_chat)

        livaCanvasView = findViewById(R.id.livaCanvas)
        LIVAClient.getInstance().attachView(livaCanvasView)
    }

    override fun onStart() {
        super.onStart()
        LIVAClient.getInstance().connect()
    }

    override fun onStop() {
        super.onStop()
        // Optional: disconnect when activity stops
        // LIVAClient.getInstance().disconnect()
    }
}
```

## Step 6: Handle State Changes

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    LIVAClient.getInstance().onStateChange = { state ->
        runOnUiThread {
            when (state) {
                is LIVAState.Idle -> statusText.text = "Ready"
                is LIVAState.Connecting -> statusText.text = "Connecting..."
                is LIVAState.Connected -> statusText.text = "Connected"
                is LIVAState.Animating -> statusText.text = "Speaking..."
                is LIVAState.Error -> showError(state.error)
            }
        }
    }

    LIVAClient.getInstance().onError = { error ->
        runOnUiThread { showError(error) }
    }
}
```

## Step 7: Send Messages

```kotlin
private fun sendMessage(text: String) {
    val client = OkHttpClient()

    val body = JSONObject().apply {
        put("AgentID", agentId)
        put("message", text)
        put("instance_id", "default")
    }

    val request = Request.Builder()
        .url("https://api.liva.com/messages")
        .post(body.toString().toRequestBody("application/json".toMediaType()))
        .addHeader("X-User-ID", userId)
        .build()

    client.newCall(request).enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            // Animation frames arrive via Socket.IO automatically
        }
        override fun onFailure(call: Call, e: IOException) {
            // Handle error
        }
    })
}
```

## Jetpack Compose Integration

```kotlin
import androidx.compose.runtime.Composable
import androidx.compose.ui.viewinterop.AndroidView
import com.liva.animation.LIVACanvasView
import com.liva.animation.LIVAClient

@Composable
fun LIVACanvas(
    modifier: Modifier = Modifier
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            LIVACanvasView(context).also { view ->
                LIVAClient.getInstance().attachView(view)
            }
        }
    )
}

@Composable
fun ChatScreen() {
    Column(modifier = Modifier.fillMaxSize()) {
        LIVACanvas(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
        )

        // Your chat UI
        ChatInput(onSend = { message -> sendMessage(message) })
    }

    LaunchedEffect(Unit) {
        LIVAClient.getInstance().connect()
    }
}
```

## Lifecycle Handling

```kotlin
class ChatActivity : AppCompatActivity() {
    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) {
            LIVAClient.getInstance().connect()
        }

        override fun onStop(owner: LifecycleOwner) {
            // Keep connected in background, or disconnect:
            // LIVAClient.getInstance().disconnect()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycle.addObserver(lifecycleObserver)
    }
}
```

## Troubleshooting

### Connection Issues
```kotlin
LIVAClient.getInstance().onError = { error ->
    when (error) {
        is LIVAError.ConnectionFailed ->
            Log.e("LIVA", "Connection failed: ${error.reason}")
        is LIVAError.SocketDisconnected ->
            Log.w("LIVA", "Socket disconnected, reconnecting...")
        else ->
            Log.e("LIVA", "Error: $error")
    }
}
```

### Memory Issues
The SDK auto-manages memory. If issues persist:
- Reduce resolution: `config.resolution = "256"`
- Check for memory leaks in your app
