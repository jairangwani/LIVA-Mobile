package com.liva.animation.rendering

import android.content.Context
import android.graphics.*
import android.util.AttributeSet
import android.util.Log
import android.view.Choreographer
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * Canvas view for rendering LIVA avatar animations.
 */
class LIVACanvasView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : SurfaceView(context, attrs, defStyleAttr), SurfaceHolder.Callback {

    // MARK: - Properties

    internal var animationEngine: AnimationEngine? = null
    private var baseFrameManager: BaseFrameManager? = null

    private var baseFrame: Bitmap? = null
    private var overlayFrame: Bitmap? = null
    private var overlayPosition = PointF(0f, 0f)

    private var isRendering = false
    private val choreographer = Choreographer.getInstance()

    // Content scaling
    private var contentScale = 1f
    private var contentOffsetX = 0f
    private var contentOffsetY = 0f
    private var contentWidth = 0f
    private var contentHeight = 0f

    // Paint for drawing
    private val paint = Paint().apply {
        isAntiAlias = true
        isFilterBitmap = true
    }

    // Feathered overlay rendering
    private val featherInner = 0.4f
    private val featherOuter = 0.5f
    private var featheredOverlayBitmap: Bitmap? = null
    private var featheredOverlayCanvas: Canvas? = null
    private val xfermodeClear = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)

    // Debug
    var showDebugInfo = false
    private var frameCount = 0
    private var lastFpsTime = System.currentTimeMillis()
    private var currentFps = 0.0

    // Frame tracking for debugging
    private var totalFramesRendered = 0L
    private var nullBaseFrames = 0L
    private var consecutiveNullFrames = 0
    private var lastLogTime = 0L
    private val LOG_INTERVAL_MS = 1000L  // Log every second

    companion object {
        private const val TAG = "LIVACanvasView"
    }

    private val debugPaint = Paint().apply {
        color = Color.WHITE
        textSize = 32f
        isAntiAlias = true
    }

    private val debugBgPaint = Paint().apply {
        color = Color.argb(128, 0, 0, 0)
    }

    // MARK: - Frame Callback

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (isRendering) {
                renderFrame()
                choreographer.postFrameCallback(this)
            }
        }
    }

    // MARK: - Initialization

    init {
        holder.addCallback(this)
        setZOrderOnTop(false)
    }

    // MARK: - SurfaceHolder.Callback

    override fun surfaceCreated(holder: SurfaceHolder) {
        startRenderLoop()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        updateContentLayout()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopRenderLoop()
    }

    // MARK: - Layout

    private fun updateContentLayout() {
        val base = baseFrame ?: return

        val viewWidth = width.toFloat()
        val viewHeight = height.toFloat()

        if (viewWidth == 0f || viewHeight == 0f) return

        val imageWidth = base.width.toFloat()
        val imageHeight = base.height.toFloat()

        val widthRatio = viewWidth / imageWidth
        val heightRatio = viewHeight / imageHeight
        contentScale = minOf(widthRatio, heightRatio)

        contentWidth = imageWidth * contentScale
        contentHeight = imageHeight * contentScale

        contentOffsetX = (viewWidth - contentWidth) / 2
        contentOffsetY = (viewHeight - contentHeight) / 2
    }

    // MARK: - Render Loop

    fun startRenderLoop() {
        if (!isRendering) {
            isRendering = true
            lastFpsTime = System.currentTimeMillis()
            choreographer.postFrameCallback(frameCallback)
        }
    }

    fun stopRenderLoop() {
        isRendering = false
        choreographer.removeFrameCallback(frameCallback)
    }

    private fun renderFrame() {
        // Update FPS counter
        frameCount++
        totalFramesRendered++
        val currentTime = System.currentTimeMillis()
        if (currentTime - lastFpsTime >= 1000) {
            currentFps = frameCount * 1000.0 / (currentTime - lastFpsTime)
            frameCount = 0
            lastFpsTime = currentTime
        }

        // Get next frame from animation engine
        val renderFrame = animationEngine?.getNextFrame()
        val frameReceived = renderFrame != null
        val baseImageReceived = renderFrame?.baseImage != null

        if (renderFrame != null) {
            baseFrame = renderFrame.baseImage
            overlayFrame = renderFrame.overlayImage
            overlayPosition = renderFrame.overlayPosition
        }

        // Track null frames
        if (baseFrame == null) {
            nullBaseFrames++
            consecutiveNullFrames++
            // Log immediately when we get null frames
            Log.w(TAG, "NULL BASE FRAME #$consecutiveNullFrames - frameReceived=$frameReceived, baseImageReceived=$baseImageReceived")
        } else {
            if (consecutiveNullFrames > 0) {
                Log.d(TAG, "Recovered from $consecutiveNullFrames consecutive null frames")
            }
            consecutiveNullFrames = 0
        }

        // Periodic logging every second
        if (currentTime - lastLogTime >= LOG_INTERVAL_MS) {
            val nullRate = if (totalFramesRendered > 0) {
                (nullBaseFrames * 100.0 / totalFramesRendered)
            } else 0.0
            val mode = animationEngine?.mode?.name ?: "UNKNOWN"
            val queuedFrames = animationEngine?.queuedFrameCount ?: 0
            val hasBuffered = animationEngine?.hasBufferedFrames ?: false

            Log.i(TAG, "=== RENDER STATS === FPS: %.1f | Total: %d | NullFrames: %d (%.1f%%) | Mode: %s | Queue: %d | Buffered: %s | BaseFrame: %s".format(
                currentFps,
                totalFramesRendered,
                nullBaseFrames,
                nullRate,
                mode,
                queuedFrames,
                hasBuffered,
                if (baseFrame != null) "${baseFrame!!.width}x${baseFrame!!.height}" else "NULL"
            ))
            lastLogTime = currentTime
        }

        // Draw to surface
        val canvas: Canvas? = try {
            holder.lockCanvas()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to lock canvas: ${e.message}")
            null
        }

        canvas?.let {
            try {
                drawFrame(it)
            } finally {
                holder.unlockCanvasAndPost(it)
            }
        }
    }

    private fun drawFrame(canvas: Canvas) {
        // Clear canvas
        canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)

        // Update layout if base frame changed
        if (baseFrame != null && contentWidth == 0f) {
            updateContentLayout()
        }

        // Draw base frame
        baseFrame?.let { base ->
            val destRect = RectF(
                contentOffsetX,
                contentOffsetY,
                contentOffsetX + contentWidth,
                contentOffsetY + contentHeight
            )
            canvas.drawBitmap(base, null, destRect, paint)
        }

        // Draw overlay frame with feathered edges at position
        overlayFrame?.let { overlay ->
            val scaledX = contentOffsetX + overlayPosition.x * contentScale
            val scaledY = contentOffsetY + overlayPosition.y * contentScale
            val overlayWidth = overlay.width * contentScale
            val overlayHeight = overlay.height * contentScale

            val destRect = RectF(
                scaledX,
                scaledY,
                scaledX + overlayWidth,
                scaledY + overlayHeight
            )

            // Apply feathered overlay
            val feathered = createFeatheredOverlay(overlay)
            canvas.drawBitmap(feathered, null, destRect, paint)
        }

        // Draw debug info
        if (showDebugInfo) {
            drawDebugInfo(canvas)
        }
    }

    private fun drawDebugInfo(canvas: Canvas) {
        val text = String.format("FPS: %.1f | Frames: %d",
            currentFps,
            animationEngine?.queuedFrameCount ?: 0
        )

        val textWidth = debugPaint.measureText(text)
        canvas.drawRect(8f, 8f, textWidth + 24f, 48f, debugBgPaint)
        canvas.drawText(text, 16f, 38f, debugPaint)
    }

    // MARK: - Frame Updates

    internal fun setBaseFrame(bitmap: Bitmap?) {
        baseFrame = bitmap
        updateContentLayout()
    }

    internal fun setOverlayFrame(bitmap: Bitmap?, position: PointF) {
        overlayFrame = bitmap
        overlayPosition = position
    }

    /**
     * Set the base frame manager for idle animations.
     */
    internal fun setBaseFrameManager(manager: BaseFrameManager?) {
        baseFrameManager = manager

        // Show first idle frame immediately if available
        manager?.getCurrentIdleFrame()?.let { firstFrame ->
            setBaseFrame(firstFrame)
        }
    }

    // MARK: - Feathered Overlay Rendering

    /**
     * Creates a feathered overlay bitmap with radial gradient mask.
     */
    private fun createFeatheredOverlay(overlay: Bitmap): Bitmap {
        val width = overlay.width
        val height = overlay.height

        // Ensure we have a properly sized offscreen bitmap
        if (featheredOverlayBitmap == null ||
            featheredOverlayBitmap?.width != width ||
            featheredOverlayBitmap?.height != height) {
            featheredOverlayBitmap?.recycle()
            featheredOverlayBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            featheredOverlayCanvas = Canvas(featheredOverlayBitmap!!)
        }

        val canvas = featheredOverlayCanvas ?: return overlay
        val bitmap = featheredOverlayBitmap ?: return overlay

        // Clear previous content
        bitmap.eraseColor(Color.TRANSPARENT)

        // Draw the overlay image
        canvas.drawBitmap(overlay, 0f, 0f, null)

        // Create radial gradient for feathering
        val cx = width / 2f
        val cy = height / 2f
        val minDim = minOf(width, height).toFloat()
        val innerRadius = minDim * featherInner
        val outerRadius = minDim * featherOuter

        // Create radial gradient - transparent center, opaque edges
        val gradient = RadialGradient(
            cx, cy,
            outerRadius,
            intArrayOf(Color.TRANSPARENT, Color.argb((255 * 0.95f).toInt(), 0, 0, 0)),
            floatArrayOf(innerRadius / outerRadius, 1f),
            Shader.TileMode.CLAMP
        )

        // Apply mask using DST_OUT (erase edges)
        val maskPaint = Paint().apply {
            isAntiAlias = true
            shader = gradient
            xfermode = xfermodeClear
        }

        canvas.drawCircle(cx, cy, outerRadius, maskPaint)

        return bitmap
    }

    // MARK: - Public Properties

    val fps: Double
        get() = currentFps

    val isActive: Boolean
        get() = isRendering
}
