//
//  CanvasView.swift
//  LIVAAnimation
//
//  High-performance canvas view for avatar animation rendering.
//

import UIKit

/// Canvas view for rendering LIVA avatar animations
public class LIVACanvasView: UIView {

    // MARK: - Properties

    /// Current base frame image
    private var baseFrame: UIImage?

    /// Current overlay frame image
    private var overlayFrame: UIImage?

    /// Overlay frames with positions (multiple overlays supported)
    private var overlayFrames: [(image: UIImage, frame: CGRect)] = []

    /// Display link for render loop
    private var displayLink: CADisplayLink?

    /// Whether rendering is active
    private var isRendering = false

    /// Scale factor for content
    private var contentScale: CGFloat = 1.0

    /// Content size (for aspect fit)
    private var contentSize: CGSize = .zero

    /// Content offset (for centering)
    private var contentOffset: CGPoint = .zero

    // MARK: - Performance

    /// Use Core Animation for compositing
    private var baseImageLayer: CALayer?
    private var overlayImageLayers: [CALayer] = []

    // MARK: - Feathered Overlay

    /// Inner radius for feather (as fraction of min dimension)
    private let featherInner: CGFloat = 0.4
    /// Outer radius for feather (as fraction of min dimension)
    private let featherOuter: CGFloat = 0.5
    /// Cached feathered overlay image
    private var cachedFeatheredOverlay: UIImage?
    private var cachedOverlaySize: CGSize = .zero

    // MARK: - Debug

    /// Show debug overlay
    public var showDebugInfo: Bool = true  // Default ON for testing

    /// Frame counter for FPS calculation
    private var frameCount = 0
    private var lastFPSTime: CFTimeInterval = 0
    private var currentFPS: Double = 0

    /// Debug text layer for real-time info
    private var debugTextLayer: CATextLayer?

    /// Current debug info from animation engine
    private var debugFPS: Double = 0
    private var debugFrameNumber: Int = 0
    private var debugTotalFrames: Int = 0
    private var debugAnimationName: String = ""
    private var debugMode: String = "idle"
    private var debugHasOverlay: Bool = false
    private var debugOverlayKey: String = ""
    private var debugOverlaySeq: Int = 0
    private var debugChunkIndex: Int = 0

    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear
        contentMode = .scaleAspectFit
        isOpaque = false
        clipsToBounds = true

        // Set up layer-based rendering for better performance
        setupLayers()
    }

    private func setupLayers() {
        // Base image layer
        baseImageLayer = CALayer()
        baseImageLayer?.contentsGravity = .resizeAspect
        baseImageLayer?.contentsScale = UIScreen.main.scale
        layer.addSublayer(baseImageLayer!)

        // Overlay image layers will be created dynamically as needed

        // Debug text layer (always on top)
        setupDebugLayer()
    }

    private func setupDebugLayer() {
        debugTextLayer = CATextLayer()
        debugTextLayer?.contentsScale = UIScreen.main.scale
        debugTextLayer?.fontSize = 12
        debugTextLayer?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        debugTextLayer?.foregroundColor = UIColor.white.cgColor
        debugTextLayer?.backgroundColor = UIColor.black.withAlphaComponent(0.85).cgColor
        debugTextLayer?.cornerRadius = 6
        debugTextLayer?.alignmentMode = .left
        debugTextLayer?.isWrapped = true
        debugTextLayer?.frame = CGRect(x: 10, y: 10, width: 280, height: 60)
        layer.addSublayer(debugTextLayer!)
    }

    /// Update debug info from animation engine (called on every frame)
    public func updateDebugInfo(fps: Double, frameNumber: Int, totalFrames: Int, animationName: String, mode: String, hasOverlay: Bool, overlayKey: String = "", overlaySeq: Int = 0, chunkIndex: Int = 0) {
        debugFPS = fps
        debugFrameNumber = frameNumber
        debugTotalFrames = totalFrames
        debugAnimationName = animationName
        debugMode = mode
        debugHasOverlay = hasOverlay
        debugOverlayKey = overlayKey
        debugOverlaySeq = overlaySeq
        debugChunkIndex = chunkIndex

        updateDebugText()
    }

    private func updateDebugText() {
        guard showDebugInfo, let textLayer = debugTextLayer else {
            debugTextLayer?.isHidden = true
            return
        }

        debugTextLayer?.isHidden = false

        let modeEmoji = debugMode == "overlay" ? "🎬" : "💤"
        let overlayInfo = debugHasOverlay ? "c\(debugChunkIndex) f\(debugOverlaySeq)" : "none"

        let text = """
        \(modeEmoji) \(debugMode.uppercased()) | \(String(format: "%.0f", debugFPS)) FPS
        Base: \(debugFrameNumber)/\(debugTotalFrames) | Ovr: \(overlayInfo)
        \(debugAnimationName)
        """

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = text
        CATransaction.commit()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateContentLayout()
    }

    private func updateContentLayout() {
        guard let baseImage = baseFrame else {
            baseImageLayer?.frame = bounds
            return
        }

        // Calculate aspect-fit scaling
        let imageSize = baseImage.size
        let viewSize = bounds.size

        let widthRatio = viewSize.width / imageSize.width
        let heightRatio = viewSize.height / imageSize.height
        contentScale = min(widthRatio, heightRatio)

        contentSize = CGSize(
            width: imageSize.width * contentScale,
            height: imageSize.height * contentScale
        )

        contentOffset = CGPoint(
            x: (viewSize.width - contentSize.width) / 2,
            y: (viewSize.height - contentSize.height) / 2
        )

        // Update base layer frame
        baseImageLayer?.frame = CGRect(
            origin: contentOffset,
            size: contentSize
        )
    }

    // MARK: - Rendering

    public override func draw(_ rect: CGRect) {
        guard !useLayerRendering else { return }

        guard let context = UIGraphicsGetCurrentContext() else { return }

        // Clear the context
        context.clear(rect)

        // Draw base frame (aspect fit)
        if let base = baseFrame {
            let imageSize = base.size
            let widthRatio = rect.width / imageSize.width
            let heightRatio = rect.height / imageSize.height
            let scale = min(widthRatio, heightRatio)

            let scaledSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )

            let x = (rect.width - scaledSize.width) / 2
            let y = (rect.height - scaledSize.height) / 2

            base.draw(in: CGRect(x: x, y: y, width: scaledSize.width, height: scaledSize.height))

            // Draw overlays at scaled positions
            for (overlayImage, overlayRect) in overlayFrames {
                let scaledX = x + overlayRect.origin.x * scale
                let scaledY = y + overlayRect.origin.y * scale
                let scaledWidth = overlayRect.width * scale
                let scaledHeight = overlayRect.height * scale

                overlayImage.draw(in: CGRect(
                    x: scaledX,
                    y: scaledY,
                    width: scaledWidth,
                    height: scaledHeight
                ))
            }
        }

        // Draw debug info if enabled
        if showDebugInfo {
            drawDebugInfo(in: context, rect: rect)
        }
    }

    /// Use layer-based rendering (more efficient)
    private var useLayerRendering: Bool = true

    private func renderWithLayers() {
        // Update base layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let base = baseFrame {
            baseImageLayer?.contents = base.cgImage
            baseImageLayer?.frame = CGRect(origin: contentOffset, size: contentSize)
        }

        // Remove old overlay layers
        overlayImageLayers.forEach { $0.removeFromSuperlayer() }
        overlayImageLayers.removeAll()

        // Create new overlay layers for each overlay
        for (overlayImage, overlayRect) in overlayFrames {
            let scaledPosition = CGPoint(
                x: contentOffset.x + overlayRect.origin.x * contentScale,
                y: contentOffset.y + overlayRect.origin.y * contentScale
            )

            let overlayScaledSize = CGSize(
                width: overlayRect.width * contentScale,
                height: overlayRect.height * contentScale
            )

            let overlayLayer = CALayer()
            overlayLayer.contentsGravity = .resizeAspect
            overlayLayer.contentsScale = UIScreen.main.scale
            overlayLayer.contents = overlayImage.cgImage
            overlayLayer.frame = CGRect(origin: scaledPosition, size: overlayScaledSize)

            layer.addSublayer(overlayLayer)
            overlayImageLayers.append(overlayLayer)
        }

        CATransaction.commit()
    }

    // MARK: - Feathered Overlay Rendering

    /// Creates a feathered overlay image with radial gradient mask
    private func createFeatheredOverlay(_ overlay: UIImage) -> UIImage? {
        let size = overlay.size
        guard size.width > 0 && size.height > 0 else { return overlay }

        // Check cache - if same size, skip recreation
        if cachedOverlaySize == size, let cached = cachedFeatheredOverlay {
            // Still need to apply to new image, but can reuse gradient calculation approach
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let feathered = renderer.image { context in
            let cgContext = context.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Draw the overlay image
            overlay.draw(in: rect)

            // Create radial gradient mask for feathering
            let cx = size.width / 2
            let cy = size.height / 2
            let minDim = min(size.width, size.height)
            let innerRadius = minDim * featherInner
            let outerRadius = minDim * featherOuter

            // Apply mask using destination-out (erase edges)
            cgContext.saveGState()
            cgContext.setBlendMode(.destinationOut)

            // Create radial gradient - transparent center, opaque edges
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors: [CGColor] = [
                UIColor(white: 0, alpha: 0).cgColor,      // Center: transparent
                UIColor(white: 0, alpha: 0.95).cgColor    // Edge: mostly opaque
            ]
            let locations: [CGFloat] = [0, 1]

            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
                cgContext.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: cx, y: cy),
                    startRadius: innerRadius,
                    endCenter: CGPoint(x: cx, y: cy),
                    endRadius: outerRadius,
                    options: [.drawsAfterEndLocation]
                )
            }

            cgContext.restoreGState()
        }

        cachedOverlaySize = size
        return feathered
    }

    private func drawDebugInfo(in context: CGContext, rect: CGRect) {
        let debugText = String(format: "FPS: %.1f | Frame: %d", currentFPS, frameCount)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor.white
        ]

        // Draw background
        context.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(CGRect(x: 8, y: 8, width: 120, height: 20))

        // Draw text
        (debugText as NSString).draw(
            at: CGPoint(x: 12, y: 10),
            withAttributes: attributes
        )
    }

    // MARK: - Frame Updates

    /// Update the base frame
    func setBaseFrame(_ image: UIImage?) {
        baseFrame = image
        if useLayerRendering {
            updateContentLayout()
            renderWithLayers()
        } else {
            setNeedsDisplay()
        }
    }

    /// Render frame with base + multiple overlays (NEW - used by LIVAAnimationEngine)
    /// - Parameters:
    ///   - base: Base animation frame
    ///   - overlays: Array of (overlay image, rect) pairs
    func renderFrame(base: UIImage, overlays: [(image: UIImage, frame: CGRect)]) {
        let start = CACurrentMediaTime()
        baseFrame = base
        overlayFrames = overlays

        if useLayerRendering {
            updateContentLayout()
            renderWithLayers()
        } else {
            setNeedsDisplay()
        }

        let elapsed = CACurrentMediaTime() - start
        // Log slow renders (> 5ms)
        if elapsed > 0.005 {
            livaLog("[CanvasView] ⏱️ Slow render: \(String(format: "%.2f", elapsed * 1000))ms, overlays=\(overlays.count)")
        }
    }

    // MARK: - Display Link (Legacy - No Longer Used)

    /// Legacy render loop - no longer used (LIVAAnimationEngine handles rendering directly)
    /// Kept as no-op for backward compatibility
    func startRenderLoop() {
        // No-op: New animation engine (LIVAAnimationEngine) handles rendering
    }

    /// Stop legacy render loop - no-op since loop is never started
    func stopRenderLoop() {
        // No-op: New animation engine handles rendering, no display link to stop
    }

    // MARK: - Cleanup

    deinit {
        stopRenderLoop()
    }
}

// MARK: - Public Interface

public extension LIVACanvasView {
    /// Current FPS
    var fps: Double {
        return currentFPS
    }

    /// Whether currently rendering
    var isActive: Bool {
        return isRendering
    }
}
