// @know entity Configuration_Android
package com.liva.animation.core

/**
 * Configuration for LIVA Animation SDK.
 *
 * @param serverUrl Backend server URL
 * @param userId User identifier
 * @param agentId Agent identifier
 * @param instanceId Session instance ID (default: "default")
 * @param resolution Canvas resolution (default: "512")
 */
data class LIVAConfiguration(
    val serverUrl: String,
    val userId: String,
    val agentId: String,
    val instanceId: String = "default",
    val resolution: String = "512"
)

/**
 * SDK connection state.
 */
sealed class LIVAState {
    object Idle : LIVAState()
    object Connecting : LIVAState()
    object Connected : LIVAState()
    object Animating : LIVAState()
    data class Error(val error: LIVAError) : LIVAState()
}

/**
 * SDK errors.
 */
sealed class LIVAError : Exception() {
    object NotConfigured : LIVAError()
    data class ConnectionFailed(val reason: String) : LIVAError()
    object SocketDisconnected : LIVAError()
    object FrameDecodingFailed : LIVAError()
    object AudioPlaybackFailed : LIVAError()
    data class Unknown(override val message: String) : LIVAError()
}
