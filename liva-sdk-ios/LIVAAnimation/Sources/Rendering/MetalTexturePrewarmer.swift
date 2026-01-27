//
//  MetalTexturePrewarmer.swift
//  LIVAAnimation
//
//  Pre-warms Metal textures by uploading them to GPU gradually
//  This prevents the freeze when all textures upload at once on first draw
//

import UIKit
import Metal
import MetalKit

/// Pre-warms Metal textures by uploading them to GPU gradually
/// Spreads the GPU upload load across multiple frames instead of all at once
class MetalTexturePrewarmer {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Texture cache for Metal textures
    /// Once uploaded, we reuse these instead of uploading again
    private var textureCache: [String: MTLTexture] = [:]
    private let textureLock = NSLock()

    /// Background upload queue (uploads happen immediately but in background)
    private let uploadQueue_dispatch = DispatchQueue(
        label: "com.liva.textureUpload",
        qos: .userInitiated,
        attributes: .concurrent  // Allow parallel uploads
    )

    // MARK: - Initialization

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[MetalTexturePrewarmer] Failed to create Metal device")
            return nil
        }

        guard let commandQueue = device.makeCommandQueue() else {
            print("[MetalTexturePrewarmer] Failed to create command queue")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        print("[MetalTexturePrewarmer] ✅ Initialized with device: \(device.name)")
    }

    // MARK: - Public Methods

    /// Upload image to GPU immediately (non-blocking - happens in background)
    /// This is called right after image decode completes
    /// All textures upload at startup, preventing freezes during playback
    func uploadImmediately(image: UIImage, key: String) {
        // Don't upload if already uploaded
        textureLock.lock()
        let alreadyUploaded = textureCache[key] != nil
        textureLock.unlock()

        if alreadyUploaded {
            return
        }

        // Upload on background queue (non-blocking)
        uploadQueue_dispatch.async { [weak self] in
            self?.uploadToGPU(image: image, key: key)
        }
    }

    /// Get pre-warmed texture (returns nil if not uploaded yet)
    func getTexture(forKey key: String) -> MTLTexture? {
        textureLock.lock()
        defer { textureLock.unlock() }
        return textureCache[key]
    }

    /// Check if texture is ready on GPU
    func isTextureReady(forKey key: String) -> Bool {
        textureLock.lock()
        defer { textureLock.unlock() }
        return textureCache[key] != nil
    }

    /// Get upload status (for diagnostics)
    func getUploadStatus() -> Int {
        textureLock.lock()
        defer { textureLock.unlock() }
        return textureCache.count
    }

    /// Clear all cached textures
    func clearCache() {
        textureLock.lock()
        defer { textureLock.unlock() }
        textureCache.removeAll()

        print("[MetalTexturePrewarmer] 🗑️ Cleared all cached textures")
    }

    // MARK: - Private Methods

    /// Upload image to GPU as Metal texture
    private func uploadToGPU(image: UIImage, key: String) {
        let startTime = CACurrentMediaTime()

        // Convert UIImage to CGImage
        guard let cgImage = image.cgImage else {
            print("[MetalTexturePrewarmer] ⚠️ Failed to get CGImage from UIImage: \(key)")
            return
        }

        let width = cgImage.width
        let height = cgImage.height

        // Create texture descriptor
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .renderTarget]

        // Create Metal texture
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            print("[MetalTexturePrewarmer] ⚠️ Failed to create Metal texture: \(key)")
            return
        }

        // Get pixel data from CGImage
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            print("[MetalTexturePrewarmer] ⚠️ Failed to create CGContext: \(key)")
            return
        }

        // Draw image into context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Upload pixel data to GPU texture
        guard let pixelData = context.data else {
            print("[MetalTexturePrewarmer] ⚠️ Failed to get pixel data: \(key)")
            return
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )

        // Store in cache
        textureLock.lock()
        textureCache[key] = texture
        textureLock.unlock()

        let uploadTime = (CACurrentMediaTime() - startTime) * 1000

        if uploadTime > 10 {
            print("[MetalTexturePrewarmer] ⏱️ Uploaded \(key): \(String(format: "%.1f", uploadTime))ms (\(width)x\(height))")
        }
    }
}
