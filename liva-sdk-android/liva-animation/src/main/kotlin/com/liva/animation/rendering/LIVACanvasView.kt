// @know entity LIVACanvasView_Android
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

    // Feathered overlay rendering — double-buffered to prevent flicker.
    // While the SurfaceHolder draws buffer A, we prepare buffer B for the next frame.
    private val featherInner = 0.4f
    private val featherOuter = 0.5f
    private var featheredBitmapA: Bitmap? = null
    private var featheredCanvasA: Canvas? = null
    private var featheredBitmapB: Bitmap? = null
    private var featheredCanvasB: Canvas? = null
    private var useBufferA = true  // Toggle each frame
    private val xfermodeClear = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)

    // Idle frame rate throttling (R57 fix)
    // Web uses 15fps during idle to save battery. Full rate during talking.
    private var lastIdleDrawTime = 0L
    private val IDLE_FRAME_INTERVAL_MS = (1000.0 / 15.0).toLong()  // ~66ms = 15fps

    // Debug
    var showDebugInfo = false
    /** Enable verbose per-frame logging for flicker diagnosis. Use with logcat tag "LIVACanvasView". */
    var diagnosticMode = false
    private var frameCount = 0
    private var lastFpsTime = System.currentTimeMillis()
    private var currentFps = 0.0
    private var renderFrameCount = 0  // Total render calls for diagnostic logging
    private var nullOverlayCount = 0  // Consecutive null overlay frames
    private var recycledCount = 0     // Consecutive recycled bitmap draws

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
        // aspect-fill (matches iOS): avatar fills the view, may crop edges
        contentScale = maxOf(widthRatio, heightRatio)

        contentWidth = imageWidth * contentScale
        contentHeight = imageHeight * contentScale

        contentOffsetX = (viewWidth - contentWidth) / 2
        contentOffsetY = (viewHeight - contentHeight) / 2
    }

    // MARK: - Render Loop

    internal fun startRenderLoop() {
        if (!isRendering) {
            isRendering = true
            lastFpsTime = System.currentTimeMillis()
            choreographer.postFrameCallback(frameCallback)
        }
    }

    internal fun stopRenderLoop() {
        isRendering = false
        choreographer.removeFrameCallback(frameCallback)
    }

    private fun renderFrame() {
        val currentTime = System.currentTimeMillis()

        // R57 FIX: Throttle frame rate during idle to save battery
        // Full rate during talking/transition for smooth lip sync
        val engine = animationEngine
        if (engine != null && engine.mode == AnimationMode.IDLE) {
            if (currentTime - lastIdleDrawTime < IDLE_FRAME_INTERVAL_MS) {
                return  // Skip this frame, Choreographer will call again next vsync
            }
            lastIdleDrawTime = currentTime
        }

        // Update FPS counter
        frameCount++
        if (currentTime - lastFpsTime >= 1000) {
            currentFps = frameCount * 1000.0 / (currentTime - lastFpsTime)
            frameCount = 0
            lastFpsTime = currentTime
        }

        // Get next frame from animation engine
        engine?.getNextFrame()?.let { frame ->
            baseFrame = frame.baseImage
            overlayFrame = frame.overlayImage
            overlayPosition = frame.overlayPosition
        }

        // Draw to surface
        val canvas: Canvas? = try {
            holder.lockCanvas()
        } catch (e: Exception) {
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

        // Snapshot bitmap references to locals — prevents race with LruCache eviction
        val base = baseFrame
        val overlay = overlayFrame
        val pos = overlayPosition

        // Update layout if base frame changed
        if (base != null && contentWidth == 0f) {
            updateContentLayout()
        }

        // Draw base frame (guard against recycled bitmaps from cache eviction)
        if (base != null && !base.isRecycled) {
            val destRect = RectF(
                contentOffsetX,
                contentOffsetY,
                contentOffsetX + contentWidth,
                contentOffsetY + contentHeight
            )
            canvas.drawBitmap(base, null, destRect, paint)
        }

        // Draw overlay frame with feathered edges at position
        if (overlay != null && !overlay.isRecycled) {
            val scaledX = contentOffsetX + pos.x * contentScale
            val scaledY = contentOffsetY + pos.y * contentScale
            val overlayWidth = overlay.width * contentScale
            val overlayHeight = overlay.height * contentScale

            val destRect = RectF(
                scaledX,
                scaledY,
                scaledX + overlayWidth,
                scaledY + overlayHeight
            )

            // Apply feathered overlay (double-buffered, safe)
            val feathered = createFeatheredOverlay(overlay)
            if (!feathered.isRecycled) {
                canvas.drawBitmap(feathered, null, destRect, paint)
            }
        }

        // Diagnostic logging for flicker analysis
        if (diagnosticMode) {
            renderFrameCount++
            val mode = animationEngine?.mode?.name ?: "?"
            if (mode == "TALKING") {
                val baseOk = base != null && !base.isRecycled
                val overlayOk = overlay != null && !overlay.isRecycled
                val baseInfo = if (base == null) "null" else if (base.isRecycled) "RECYCLED" else "${base.width}x${base.height}"
                val overlayInfo = if (overlay == null) "null" else if (overlay.isRecycled) "RECYCLED" else "${overlay.width}x${overlay.height}"

                if (!overlayOk) {
                    nullOverlayCount++
                    if (nullOverlayCount <= 3 || nullOverlayCount % 10 == 0) {
                        Log.w("LIVACanvasView", "FLICKER #$renderFrameCount: overlay=$overlayInfo, base=$baseInfo, consecutive=$nullOverlayCount")
                    }
                } else {
                    if (nullOverlayCount > 0) {
                        Log.d("LIVACanvasView", "FLICKER-END #$renderFrameCount: overlay resumed after $nullOverlayCount null frames")
                        nullOverlayCount = 0
                    }
                }

                if (base != null && base.isRecycled) {
                    recycledCount++
                    Log.e("LIVACanvasView", "RECYCLED-BASE #$renderFrameCount: base bitmap recycled during draw!")
                }
                if (overlay != null && overlay.isRecycled) {
                    recycledCount++
                    Log.e("LIVACanvasView", "RECYCLED-OVERLAY #$renderFrameCount: overlay bitmap recycled during draw!")
                }
            }
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
     * Uses double-buffering: while the SurfaceHolder draws one buffer,
     * we write to the other — prevents flicker from eraseColor race.
     */
    private fun createFeatheredOverlay(overlay: Bitmap): Bitmap {
        val width = overlay.width
        val height = overlay.height

        // Toggle buffer each frame
        useBufferA = !useBufferA

        // Get the write buffer (not the one being displayed)
        var bitmap = if (useBufferA) featheredBitmapA else featheredBitmapB
        var offCanvas = if (useBufferA) featheredCanvasA else featheredCanvasB

        // Ensure write buffer is properly sized
        if (bitmap == null || bitmap.width != width || bitmap.height != height) {
            bitmap?.recycle()
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            offCanvas = Canvas(bitmap)
            if (useBufferA) {
                featheredBitmapA = bitmap
                featheredCanvasA = offCanvas
            } else {
                featheredBitmapB = bitmap
                featheredCanvasB = offCanvas
            }
        }

        val canvas = offCanvas ?: return overlay

        // Clear previous content (safe — this buffer is NOT being displayed)
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
