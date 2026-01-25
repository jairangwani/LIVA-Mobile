package com.liva.flutter

import android.content.Context
import android.util.Log
import android.view.View
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

// Import real SDK classes
import com.liva.animation.core.LIVAClient
import com.liva.animation.core.LIVAConfiguration
import com.liva.animation.core.LIVAState
import com.liva.animation.core.LIVAError
import com.liva.animation.rendering.LIVACanvasView

private const val TAG = "LIVAPlugin"

/**
 * Flutter plugin for LIVA Animation SDK.
 *
 * This plugin bridges the native LIVA Animation SDK to Flutter.
 */
class LIVAAnimationPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    // SDK components
    private var client: LIVAClient? = null
    private var canvasView: LIVACanvasView? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        // Method channel for commands
        channel = MethodChannel(binding.binaryMessenger, "com.liva.animation")
        channel.setMethodCallHandler(this)

        // Event channel for callbacks
        eventChannel = EventChannel(binding.binaryMessenger, "com.liva.animation/events")
        eventChannel.setStreamHandler(this)

        // Register platform view factory
        binding.platformViewRegistry.registerViewFactory(
            "com.liva.animation/canvas",
            LIVACanvasViewFactory(this)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        client?.release()
        client = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                // Flutter passes the config map directly as arguments, not wrapped in "config" key
                @Suppress("UNCHECKED_CAST")
                val config = call.arguments as? Map<String, Any>
                Log.d(TAG, "initialize called with arguments: ${call.arguments}")
                if (config != null) {
                    initializeSDK(config)
                    result.success(null)
                } else {
                    result.error("INVALID_CONFIG", "Config is required", null)
                }
            }
            "connect" -> {
                Log.d(TAG, "connect() called, client=${client != null}")
                try {
                    client?.connect()
                    Log.d(TAG, "connect() completed")
                } catch (e: Exception) {
                    Log.e(TAG, "Exception in connect(): ${e.message}", e)
                }
                result.success(null)
            }
            "disconnect" -> {
                client?.disconnect()
                result.success(null)
            }
            "release" -> {
                client?.release()
                client = null
                result.success(null)
            }
            "isConnected" -> {
                result.success(client?.isConnected ?: false)
            }
            "getDebugInfo" -> {
                result.success(mapOf(
                    "state" to stateToString(client?.state ?: LIVAState.Idle),
                    "isConnected" to (client?.isConnected ?: false),
                    "debugDescription" to (client?.debugDescription ?: "Not initialized")
                ))
            }
            "setDebugMode" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                canvasView?.showDebugInfo = enabled
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initializeSDK(config: Map<String, Any>) {
        Log.d(TAG, "initializeSDK called with config: $config")

        val serverUrl = config["serverUrl"] as? String
        val userId = config["userId"] as? String
        val agentId = config["agentId"] as? String
        val instanceId = config["instanceId"] as? String ?: "default"

        if (serverUrl == null) {
            Log.e(TAG, "serverUrl is null!")
            return
        }
        if (userId == null) {
            Log.e(TAG, "userId is null!")
            return
        }
        if (agentId == null) {
            Log.e(TAG, "agentId is null!")
            return
        }

        Log.d(TAG, "Creating LIVAConfiguration: serverUrl=$serverUrl, userId=$userId, agentId=$agentId")
        val livaConfig = LIVAConfiguration(
            serverUrl = serverUrl,
            userId = userId,
            agentId = agentId,
            instanceId = instanceId
        )

        try {
            // Get or create client
            Log.d(TAG, "Getting LIVAClient instance...")
            client = LIVAClient.getInstance()
            Log.d(TAG, "Initializing client with context...")
            client?.initialize(context)
            Log.d(TAG, "Configuring client...")
            client?.configure(livaConfig)
            Log.d(TAG, "Client configured successfully")

            // Set up callbacks
            client?.onStateChange = { state ->
                Log.d(TAG, "State changed to: $state")
                sendEvent("stateChange", stateToString(state))
            }

            client?.onError = { error ->
                Log.e(TAG, "Error received: $error")
                sendEvent("error", errorToString(error))
            }

            // Attach canvas view if already created
            canvasView?.let { view ->
                Log.d(TAG, "Attaching canvas view...")
                client?.attachView(view)
            }

            Log.d(TAG, "initializeSDK completed")
        } catch (e: Exception) {
            Log.e(TAG, "Exception in initializeSDK: ${e.message}", e)
        }
    }

    fun attachCanvasView(view: LIVACanvasView) {
        canvasView = view
        client?.attachView(view)
    }

    private fun stateToString(state: LIVAState): String {
        return when (state) {
            is LIVAState.Idle -> "idle"
            is LIVAState.Connecting -> "connecting"
            is LIVAState.Connected -> "connected"
            is LIVAState.Animating -> "animating"
            is LIVAState.Error -> "error"
        }
    }

    private fun errorToString(error: LIVAError): String {
        return when (error) {
            is LIVAError.NotConfigured -> "Not configured"
            is LIVAError.ConnectionFailed -> "Connection failed: ${error.reason}"
            is LIVAError.SocketDisconnected -> "Socket disconnected"
            is LIVAError.FrameDecodingFailed -> "Frame decoding failed"
            is LIVAError.AudioPlaybackFailed -> "Audio playback failed"
            is LIVAError.Unknown -> error.message
        }
    }

    private fun sendEvent(type: String, data: Any) {
        eventSink?.success(mapOf("type" to type, "data" to data))
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}

/**
 * Factory for creating LIVACanvasView instances.
 */
class LIVACanvasViewFactory(private val plugin: LIVAAnimationPlugin) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return LIVACanvasPlatformView(context, plugin)
    }
}

/**
 * Platform view wrapper for LIVACanvasView.
 */
class LIVACanvasPlatformView(context: Context, plugin: LIVAAnimationPlugin) : PlatformView {
    private val canvasView: LIVACanvasView = LIVACanvasView(context)

    init {
        plugin.attachCanvasView(canvasView)
    }

    override fun getView(): View = canvasView

    override fun dispose() {
        canvasView.stopRenderLoop()
    }
}
