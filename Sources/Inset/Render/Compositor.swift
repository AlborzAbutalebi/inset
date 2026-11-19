import CoreMedia
import CoreVideo
import Metal
import QuartzCore

/// A captured video frame from one source.
struct SourceFrame {
    let buffer: CVPixelBuffer
    /// Region of the buffer that contains real content, in pixels.
    let crop: CGRect
    /// Capture time on the host clock.
    let hostTime: CMTime

    var aspect: CGFloat { crop.height > 0 ? crop.width / crop.height : 16 / 9 }
}

private struct LayerUniforms {
    var destRect: SIMD4<Float> = .zero
    var uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var targetSize: SIMD2<Float> = .zero
    var texSize: SIMD2<Float> = SIMD2(1, 1)
    var color: SIMD4<Float> = .zero
    var borderColor: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var radius: Float = 0
    var opacity: Float = 1
    var shadowRadius: Float = 0
    var borderWidth: Float = 0
    var mode: Int32 = 0
}

/// GPU compositor: draws the screen and camera layers (rounded, shadowed, animated)
/// into either an encoder-bound pixel buffer or the preview drawable. Zero-copy throughout.
final class Compositor: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache!

    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw InsetError.message("Metal is not available on this Mac.")
        }
        self.device = device
        self.commandQueue = queue

        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "layer_vertex")
        desc.fragmentFunction = library.makeFunction(name: "layer_fragment")
        let att = desc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one
        att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
    }

    // MARK: Buffers

    /// An IOSurface-backed BGRA buffer for the encoder. Returns nil when the encoder is
    /// backed up (pool threshold), which simply drops that frame.
    func makeOutputBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pb
    }

    func texture(for buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }

    func flushCache() { CVMetalTextureCacheFlush(textureCache, 0) }

    // MARK: Drawing

    struct Inputs {
        var screen: SourceFrame?
        var camera: SourceFrame?
        var screenTexture: MTLTexture?
        var cameraTexture: MTLTexture?
    }

    /// Encodes the scene into `target`. `scale`/`offset` map canvas pixels to target pixels.
    func encode(scene: SceneState, layout: LayoutSnapshot, canvas: CGSize, inputs: Inputs,
                into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                scale: CGFloat, offset: CGPoint, clear: MTLClearColor) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = clear
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)

        let targetSize = SIMD2<Float>(Float(target.width), Float(target.height))
        let bg = SIMD4<Float>(Float(layout.background.r), Float(layout.background.g), Float(layout.background.b), 1)
        let short = min(canvas.width, canvas.height)

        func map(_ r: CGRect) -> SIMD4<Float> {
            SIMD4(Float(r.minX * scale + offset.x), Float(r.minY * scale + offset.y),
                  Float(r.width * scale), Float(r.height * scale))
        }

        func draw(_ u: inout LayerUniforms, texture: MTLTexture?) {
            u.targetSize = targetSize
            enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Canvas backdrop (matters when the preview is letterboxed).
        var backdrop = LayerUniforms()
        backdrop.destRect = map(CGRect(origin: .zero, size: canvas))
        backdrop.color = bg
        backdrop.mode = 2
        draw(&backdrop, texture: nil)

        func drawLayer(_ state: LayerState, frame: SourceFrame?, texture: MTLTexture?, mirror: Bool, placeholder: SIMD4<Float>) {
            guard state.opacity > 0.002, state.rect.width > 1, state.rect.height > 1 else { return }
            let dest = map(state.rect)
            if state.shadow > 0.001 {
                var sh = LayerUniforms()
                let radius = max(6, min(state.rect.width, state.rect.height) * 0.07) * scale
                var r = state.rect
                r.origin.y += radius / scale * 0.35
                sh.destRect = map(r)
                sh.radius = Float(state.radius * scale)
                sh.shadowRadius = Float(radius)
                sh.opacity = Float(state.opacity * state.shadow * 0.55)
                sh.mode = 1
                draw(&sh, texture: nil)
            }
            var u = LayerUniforms()
            u.destRect = dest
            u.radius = Float(state.radius * scale)
            u.opacity = Float(state.opacity)
            u.borderWidth = state.border > 0.001 ? Float(max(1.5, short * 0.0035) * scale) : 0
            u.borderColor = SIMD4(1, 1, 1, Float(state.border))
            if let frame, let texture {
                u.mode = 0
                u.color = bg
                u.texSize = SIMD2(Float(texture.width), Float(texture.height))
                u.uvRect = Self.fillUV(crop: frame.crop, texSize: CGSize(width: texture.width, height: texture.height),
                                       destAspect: state.rect.width / state.rect.height, mirror: mirror)
                draw(&u, texture: texture)
            } else {
                u.mode = 2
                u.color = placeholder
                draw(&u, texture: nil)
            }
        }

        let placeholder = SIMD4<Float>(0.11, 0.11, 0.13, 1)
        let screen = { drawLayer(scene.screen, frame: inputs.screen, texture: inputs.screenTexture, mirror: false, placeholder: placeholder) }
        let camera = { drawLayer(scene.camera, frame: inputs.camera, texture: inputs.cameraTexture, mirror: layout.mirrorCamera, placeholder: placeholder) }
        if scene.cameraOnTop { screen(); camera() } else { camera(); screen() }
        enc.endEncoding()
    }

    /// UV rect that aspect-fills `crop` into a destination of `destAspect`.
    static func fillUV(crop: CGRect, texSize: CGSize, destAspect: CGFloat, mirror: Bool) -> SIMD4<Float> {
        var c = crop
        let srcAspect = crop.width / max(crop.height, 1)
        if srcAspect > destAspect {
            let w = crop.height * destAspect
            c.origin.x += (crop.width - w) / 2
            c.size.width = w
        } else {
            let h = crop.width / max(destAspect, 0.01)
            c.origin.y += (crop.height - h) / 2
            c.size.height = h
        }
        var u0 = Float(c.minX / texSize.width), u1 = Float(c.maxX / texSize.width)
        let v0 = Float(c.minY / texSize.height), v1 = Float(c.maxY / texSize.height)
        if mirror { swap(&u0, &u1) }
        return SIMD4(u0, v0, u1, v1)
    }
}

enum InsetError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): m }
    }
}
