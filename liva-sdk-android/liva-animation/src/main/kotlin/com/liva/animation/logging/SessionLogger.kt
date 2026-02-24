// @know entity SessionLogger_Android
package com.liva.animation.logging

import android.util.Log
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Session-based logging system for Android SDK
 * Sends frame logs and events to backend for debugging and analysis
 *
 * Matches iOS LIVASessionLogger behavior for cross-platform consistency
 */
class SessionLogger private constructor() {

    companion object {
        private const val TAG = "SessionLogger"

        @Volatile
        private var instance: SessionLogger? = null

        fun getInstance(): SessionLogger {
            return instance ?: synchronized(this) {
                instance ?: SessionLogger().also { instance = it }
            }
        }
    }

    // Configuration
    private var serverUrl: String = "http://localhost:5003"
    var isEnabled: Boolean = true

    // Session state
    private var sessionId: String? = null
    private var userId: String? = null
    private var agentId: String? = null
    private val platform: String = "ANDROID"

    // Batching configuration
    private val BATCH_INTERVAL_MS = 1000L  // Send every 1 second
    private val MAX_BATCH_SIZE = 100       // Max 100 frames per batch

    // Batched logs
    private val frameBatch = ConcurrentLinkedQueue<JSONObject>()
    private val eventBatch = ConcurrentLinkedQueue<JSONObject>()

    // Coroutine scope for async operations
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var batchJob: Job? = null

    // ISO 8601 timestamp formatter
    private val isoDateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    /**
     * Configure backend URL
     */
    fun configure(url: String) {
        serverUrl = url.trimEnd('/')
        Log.d(TAG, "Configured with server URL: $serverUrl")

        // Verify HTTP connectivity
        scope.launch {
            try {
                val testUrl = URL("$serverUrl/health")
                val connection = testUrl.openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 3000
                connection.readTimeout = 3000

                val responseCode = connection.responseCode
                connection.disconnect()

                if (responseCode == 200) {
                    Log.d(TAG, "Backend reachable (HTTP 200)")
                } else {
                    Log.e(TAG, "Backend returned HTTP $responseCode")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Backend unreachable: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /**
     * Start a new logging session
     * @return Session ID or null if failed
     */
    fun startSession(userId: String, agentId: String): String? {
        if (!isEnabled) {
            Log.d(TAG, "Logging disabled, skipping session start")
            return null
        }

        this.userId = userId
        this.agentId = agentId

        // Generate session ID: 2026-01-28_HHMMSS_android
        val timestamp = SimpleDateFormat("yyyy-MM-dd_HHmmss", Locale.US).format(Date())
        val newSessionId = "${timestamp}_android"

        Log.d(TAG, "Attempting to start session: $newSessionId")
        Log.d(TAG, "Server URL: $serverUrl")
        Log.d(TAG, "User: $userId, Agent: $agentId")

        // Start session on background thread to avoid NetworkOnMainThreadException
        scope.launch {
            try {
                val url = URL("$serverUrl/api/log/session/start")
                Log.d(TAG, "Opening connection to: ${url.toString()}")

                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/json")
                connection.doOutput = true
                connection.connectTimeout = 5000
                connection.readTimeout = 5000

                val requestBody = JSONObject().apply {
                    put("user_id", userId)
                    put("agent_id", agentId)
                    put("platform", platform)
                    put("session_id", newSessionId)
                }

                Log.d(TAG, "Request body: ${requestBody.toString()}")

                OutputStreamWriter(connection.outputStream).use { writer ->
                    writer.write(requestBody.toString())
                    writer.flush()
                }

                val responseCode = connection.responseCode
                Log.d(TAG, "Response code: $responseCode")

                if (responseCode == 200 || responseCode == 201) {
                    sessionId = newSessionId
                    Log.d(TAG, "✅ Session started successfully: $sessionId")

                    // Start batch processing
                    startBatchProcessing()
                } else {
                    Log.e(TAG, "❌ Failed to start session: HTTP $responseCode")
                    val errorBody = connection.errorStream?.bufferedReader()?.readText()
                    Log.e(TAG, "Error response: $errorBody")
                }

                connection.disconnect()
            } catch (e: Exception) {
                Log.e(TAG, "❌ Exception starting session: ${e.javaClass.simpleName}", e)
                Log.e(TAG, "Exception message: ${e.message}")
                Log.e(TAG, "Stack trace: ${e.stackTraceToString()}")
            }
        }

        // Return session ID immediately (async start)
        return newSessionId
    }

    /**
     * End the current logging session
     */
    fun endSession() {
        val currentSessionId = sessionId ?: return

        scope.launch {
            try {
                // Flush remaining batches
                flushBatches()

                // Stop batch processing
                batchJob?.cancel()
                batchJob = null

                // Call backend to end session
                val url = URL("$serverUrl/api/log/session/end")
                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/json")
                connection.doOutput = true

                val requestBody = JSONObject().apply {
                    put("session_id", currentSessionId)
                }

                OutputStreamWriter(connection.outputStream).use { writer ->
                    writer.write(requestBody.toString())
                    writer.flush()
                }

                val responseCode = connection.responseCode
                if (responseCode == 200) {
                    Log.d(TAG, "Ended session: $currentSessionId")
                } else {
                    Log.w(TAG, "Failed to end session: HTTP $responseCode")
                }

                sessionId = null
                userId = null
                agentId = null

            } catch (e: Exception) {
                Log.e(TAG, "Error ending session", e)
            }
        }
    }

    /**
     * Log a rendered frame
     * Batched and sent every 1 second
     */
    fun logFrame(
        chunk: Int,
        seq: Int,
        anim: String,
        baseFrame: Int,
        overlayKey: String?,
        syncStatus: String,
        fps: Double,
        sprite: Int? = null,
        char: String? = null,
        buffer: String? = null,
        nextChunk: String? = null
    ) {
        if (!isEnabled || sessionId == null) return

        // Field names must match backend expectations
        val frameLog = JSONObject().apply {
            put("timestamp", isoDateFormat.format(Date()))
            put("source", platform)
            put("chunk", chunk)
            put("seq", seq)
            put("anim", anim)
            put("base_frame", baseFrame)  // Backend expects 'base_frame'
            put("overlay_key", overlayKey ?: "")  // Backend expects 'overlay_key'
            put("sync_status", syncStatus)  // Backend expects 'sync_status'
            put("fps", String.format("%.1f", fps))
            put("sprite", sprite ?: "")
            put("char", char ?: "")
            put("buffer", buffer ?: "")
            put("next_chunk", nextChunk ?: "")
        }

        frameBatch.offer(frameLog)

        // Flush if batch is full
        if (frameBatch.size >= MAX_BATCH_SIZE) {
            scope.launch {
                flushFrames()
            }
        }
    }

    /**
     * Log an important event
     */
    fun logEvent(eventType: String, details: Map<String, Any>) {
        if (!isEnabled || sessionId == null) return

        val eventLog = JSONObject().apply {
            put("timestamp", isoDateFormat.format(Date()))
            put("source", platform)
            put("session_id", sessionId)
            put("event_type", eventType)
            put("details", JSONObject(details))
        }

        eventBatch.offer(eventLog)

        // Events are sent immediately (not batched)
        scope.launch {
            flushEvents()
        }
    }

    /**
     * Start periodic batch processing
     */
    private fun startBatchProcessing() {
        batchJob?.cancel()
        batchJob = scope.launch {
            while (isActive) {
                delay(BATCH_INTERVAL_MS)
                flushBatches()
            }
        }
    }

    /**
     * Flush all pending batches
     */
    private suspend fun flushBatches() {
        flushFrames()
        flushEvents()
    }

    /**
     * Flush frame batch to backend
     */
    private suspend fun flushFrames() {
        if (frameBatch.isEmpty()) return

        val currentSessionId = sessionId ?: return

        val frames = JSONArray()
        var count = 0

        // Drain up to MAX_BATCH_SIZE frames
        while (frameBatch.isNotEmpty() && count < MAX_BATCH_SIZE) {
            frameBatch.poll()?.let { frames.put(it) }
            count++
        }

        if (frames.length() == 0) return

        withContext(Dispatchers.IO) {
            try {
                val url = URL("$serverUrl/api/log/frames-batch")
                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/json")
                connection.doOutput = true
                connection.connectTimeout = 2000
                connection.readTimeout = 2000

                // Backend expects session_id at root level + frames array
                val requestBody = JSONObject().apply {
                    put("session_id", currentSessionId)  // Required by backend
                    put("frames", frames)
                }

                OutputStreamWriter(connection.outputStream).use { writer ->
                    writer.write(requestBody.toString())
                    writer.flush()
                }

                val responseCode = connection.responseCode
                if (responseCode == 200 || responseCode == 204) {
                    Log.d(TAG, "Frame batch sent: $count frames")
                } else {
                    Log.w(TAG, "Frame batch response: HTTP $responseCode")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send frame batch: ${e.message}")
                // Don't crash on logging errors
            }
        }
    }

    /**
     * Flush event batch to backend
     */
    private suspend fun flushEvents() {
        if (eventBatch.isEmpty()) return

        withContext(Dispatchers.IO) {
            while (eventBatch.isNotEmpty()) {
                val event = eventBatch.poll() ?: continue

                try {
                    val url = URL("$serverUrl/api/log/event")
                    val connection = url.openConnection() as HttpURLConnection
                    connection.requestMethod = "POST"
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.doOutput = true
                    connection.connectTimeout = 2000
                    connection.readTimeout = 2000

                    OutputStreamWriter(connection.outputStream).use { writer ->
                        writer.write(event.toString())
                        writer.flush()
                    }

                    val responseCode = connection.responseCode
                    if (responseCode != 200 && responseCode != 204) {
                        Log.w(TAG, "Event response: HTTP $responseCode")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send event: ${e.message}")
                }
            }
        }
    }

    /**
     * Check if a session is currently active
     */
    fun isSessionActive(): Boolean {
        return sessionId != null
    }

    /**
     * Get current session ID
     */
    fun getCurrentSessionId(): String? {
        return sessionId
    }
}
