package com.liva.testapp

import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import com.liva.animation.core.LIVAClient
import com.liva.animation.core.LIVAConfiguration
import com.liva.animation.core.LIVAState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : AppCompatActivity() {

    private lateinit var canvasContainer: FrameLayout
    private lateinit var messageInput: EditText
    private lateinit var sendButton: Button

    private var livaClient: LIVAClient? = null

    companion object {
        private const val TAG = "MainActivity"
        private const val SERVER_URL = "http://10.0.2.2:5003"  // Android emulator -> host
        private const val USER_ID = "test_user_android"
        private const val AGENT_ID = "1"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        canvasContainer = findViewById(R.id.canvas_container)
        messageInput = findViewById(R.id.message_input)
        sendButton = findViewById(R.id.send_button)

        sendButton.setOnClickListener {
            val message = messageInput.text.toString()
            if (message.isNotBlank()) {
                sendMessage(message)
                messageInput.text.clear()
            }
        }

        initializeLIVA()
    }

    private fun initializeLIVA() {
        Log.d(TAG, "Initializing LIVA SDK...")

        try {
            // Get LIVAClient instance
            livaClient = LIVAClient.getInstance()

            // Initialize with context
            livaClient?.initialize(this)

            // Configure
            val config = LIVAConfiguration(
                serverUrl = SERVER_URL,
                userId = USER_ID,
                agentId = AGENT_ID,
                instanceId = "android_test",
                resolution = "512"
            )

            livaClient?.configure(config)

            // Attach canvas view
            val canvasView = livaClient?.getCanvasView()
            if (canvasView != null) {
                canvasContainer.removeAllViews()
                canvasContainer.addView(canvasView)
                Log.d(TAG, "Canvas view attached")
            } else {
                Log.e(TAG, "Canvas view is null!")
            }

            // Connect to backend
            livaClient?.connect()
            Log.d(TAG, "LIVA SDK initialized and connecting...")

        } catch (e: Exception) {
            Log.e(TAG, "Error initializing LIVA", e)
        }
    }

    private fun sendMessage(message: String) {
        Log.d(TAG, "Sending message: $message")

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val url = URL("$SERVER_URL/messages")
                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("X-User-ID", USER_ID)
                connection.doOutput = true
                connection.connectTimeout = 10000
                connection.readTimeout = 10000

                val requestBody = JSONObject().apply {
                    put("AgentID", AGENT_ID)
                    put("message", message)
                    put("instance_id", "android_test")
                    put("userResolution", "512")
                }

                connection.outputStream.use { os ->
                    os.write(requestBody.toString().toByteArray())
                }

                val responseCode = connection.responseCode
                Log.d(TAG, "Message sent, response: $responseCode")

                withContext(Dispatchers.Main) {
                    if (responseCode == 200 || responseCode == 201) {
                        Log.d(TAG, "✅ Message sent successfully")
                    } else {
                        Log.e(TAG, "❌ Failed to send message: $responseCode")
                    }
                }

                connection.disconnect()
            } catch (e: Exception) {
                Log.e(TAG, "Error sending message", e)
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        livaClient?.disconnect()
    }
}
