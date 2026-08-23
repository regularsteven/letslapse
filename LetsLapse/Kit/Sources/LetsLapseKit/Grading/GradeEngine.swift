import Foundation
import Metal
import simd

/// Compiled pipelines for the tone engine — the grading counterpart of
/// `BlendCore`, built the same way (runtime compile of shipped source).
/// Immutable after init, safe to share.
final class GradeCore: @unchecked Sendable {
    let device: MTLDevice
    let gradeTonePipeline: MTLComputePipelineState
    let basePrepPipeline: MTLComputePipelineState
    let blurHorizontalPipeline: MTLComputePipelineState
    let blurVerticalPipeline: MTLComputePipelineState
    let guidedABPipeline: MTLComputePipelineState
    let guidedResolvePipeline: MTLComputePipelineState
    let detailLumaPipeline: MTLComputePipelineState
    let textureApplyPipeline: MTLComputePipelineState
    let sharpenPipeline: MTLComputePipelineState
    let vignettePipeline: MTLComputePipelineState
    let ditherPipeline: MTLComputePipelineState

    init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw LapseError.metalUnavailable
        }
        self.device = device
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: GradeKernelSource.source, options: nil)
        } catch {
            throw LapseError.gpuSetupFailed("grade kernel compilation failed: \(error.localizedDescription)")
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw LapseError.gpuSetupFailed("missing grade kernel \(name)")
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.gradeTonePipeline = try pipeline("gradeTone")
        self.basePrepPipeline = try pipeline("basePrep")
        self.blurHorizontalPipeline = try pipeline("blurHorizontal2")
        self.blurVerticalPipeline = try pipeline("blurVertical2")
        self.guidedABPipeline = try pipeline("guidedAB")
        self.guidedResolvePipeline = try pipeline("guidedResolve")
        self.detailLumaPipeline = try pipeline("detailLuma")
        self.textureApplyPipeline = try pipeline("applyTexture")
        self.sharpenPipeline = try pipeline("applySharpen")
        self.vignettePipeline = try pipeline("applyVignette")
        self.ditherPipeline = try pipeline("finalizeDither")
    }

    func dispatch(_ pipeline: MTLComputePipelineState, encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }
}

/// The tone engine. Make one per device and reuse it; renderers are cheap
/// (a LUT and a handful of coefficients) and made per recipe.
public final class GradeEngine {
    public let device: MTLDevice
    let core: GradeCore
    let commandQueue: MTLCommandQueue

    public init(device: MTLDevice? = nil) throws {
        let core = try GradeCore(device: device)
        self.core = core
        self.device = core.device
        guard let queue = core.device.makeCommandQueue() else {
            throw LapseError.gpuSetupFailed("could not create a grade command queue")
        }
        self.commandQueue = queue
    }

    public func makeRenderer(_ recipe: GradeRecipe, reference: GradeReference) -> GradeRenderer {
        GradeRenderer(core: core, commandQueue: commandQueue, recipe: recipe, reference: reference)
    }
}

/// One recipe, ready to render. Holds the precomputed LUT/coefficients and a
/// set of reusable scratch textures — reuse one renderer across a whole blend.
/// Not thread-safe; drive it from a single worker.
public final class GradeRenderer {
    /// Mirror of the Metal `GradeParams` struct — layouts must match.
    private struct GPUGradeParams {
        var wb: simd_float3x3
        var wbNeutral: SIMD3<Float>
        var exposureGain: Float
        var kneeK: Float
        var recoveryStrength: Float
        var desatFloor: Float
        var clipDesat: Float
        var saturationGain: Float
        var vibranceCoeff: Float
        var lutEndSlope: Float
        var lutSize: UInt32
        var shadowEV: Float
        var highlightEV: Float
        var clarityGain: Float
        var blacksLift: Float
        var usesBase: UInt32
        var chromaProtect: UInt32
    }

    private struct GPUBlurParams {
        var sigma: Float
        var radius: Int32
    }

    private struct GPUGuidedParams {
        var epsilon: Float
    }

    private struct GPUDitherParams {
        var amplitude: Float
        var seed: UInt32
    }

    private struct GPUDetailParams {
        var amount: Float
        var tau: Float
        var sigma: Float
        var radius: Int32
    }

    private let core: GradeCore
    private let commandQueue: MTLCommandQueue
    public private(set) var recipe: GradeRecipe
    public let reference: GradeReference

    private var params: GPUGradeParams
    private var lut: [Float]

    // Scratch, reused across frames; reallocated when the size changes.
    private var scratchA: MTLTexture?
    private var scratchB: MTLTexture?
    private var quarter: MTLTexture?
    private var momentsA: MTLTexture?
    private var momentsB: MTLTexture?
    private var baseTexture: MTLTexture?
    private var halfLumaA: MTLTexture?
    private var halfLumaB: MTLTexture?
    private var scratchWidth = 0
    private var scratchHeight = 0

    init(core: GradeCore, commandQueue: MTLCommandQueue, recipe: GradeRecipe, reference: GradeReference) {
        self.core = core
        self.commandQueue = commandQueue
        self.recipe = recipe
        self.reference = reference

        let lut = ToneMath.toneLUT(for: recipe)
        self.lut = lut
        self.params = Self.gpuParams(recipe: recipe, reference: reference, lut: lut)
    }

    /// Points this renderer at a different recipe, keeping its scratch
    /// textures.
    ///
    /// For a grade that changes across a clip: a keyframed blend needs a new
    /// recipe every few output frames, and building a fresh renderer for each
    /// would throw away — and immediately reallocate — every scratch texture
    /// the pass owns. Only the LUT and the coefficients actually depend on the
    /// recipe, and both are cheap CPU work.
    public func restage(_ recipe: GradeRecipe) {
        guard recipe != self.recipe else { return }
        self.recipe = recipe
        let lut = ToneMath.toneLUT(for: recipe)
        self.lut = lut
        self.params = Self.gpuParams(recipe: recipe, reference: reference, lut: lut)
    }

    private static func gpuParams(
        recipe: GradeRecipe, reference: GradeReference, lut: [Float]
    ) -> GPUGradeParams {
        let recovery = max(-recipe.highlights, 0)
        let strength = max(recovery, ToneMath.recoveryBase)
        let endSlope = (lut[lut.count - 1] - lut[lut.count - 2]) * Float(lut.count - 1)
        let usesBase = recipe.shadows != 0 || recipe.highlights != 0 || recipe.clarity != 0
        let highlightAmp = recipe.highlights >= 0
            ? ToneMath.highlightLiftEV : ToneMath.highlightCutEV
        let wb = ToneMath.whiteBalanceMatrix(recipe: recipe, reference: reference)
        let white = wb * SIMD3<Float>(repeating: 1)
        let wbNeutral = white / max(simd_dot(white, ToneMath.lumaWeights), 1e-6)
        return GPUGradeParams(
            wb: wb,
            wbNeutral: wbNeutral,
            exposureGain: exp2(recipe.exposure),
            kneeK: 0.95 - 0.6 * recovery,
            recoveryStrength: strength,
            desatFloor: ToneMath.desatStrength * ToneMath.recoveryBase,
            clipDesat: ToneMath.desatStrength * recovery,
            saturationGain: 1 + ToneMath.saturationStrength * recipe.saturation,
            vibranceCoeff: ToneMath.vibranceStrength * recipe.vibrance,
            lutEndSlope: endSlope,
            lutSize: UInt32(lut.count),
            shadowEV: ToneMath.shadowLocalEV * recipe.shadows,
            highlightEV: highlightAmp * recipe.highlights,
            clarityGain: ToneMath.clarityDetailGain * recipe.clarity,
            blacksLift: max(recipe.blacks, 0),
            usesBase: usesBase ? 1 : 0,
            chromaProtect: (recipe.shadows > 0 || recipe.blacks > 0) ? 1 : 0)
    }

    /// Encodes the whole grade into `commandBuffer` and returns the output
    /// texture (renderer-owned scratch, valid until the next `encode` call).
    /// Input: scene-linear Display P3, rgba16Float. Output: display-referred
    /// [0,1] linear, same primaries, rgba16Float.
    ///
    /// `ditherFor8Bit` adds one TPDF pass at a 1/255 amplitude — pass true
    /// when the destination quantises to 8 bits (preview CGImages, JPEG
    /// export). The blend path dithers in its own encode kernel and must
    /// leave this off.
    public func encode(
        from source: MTLTexture, commandBuffer: MTLCommandBuffer, ditherFor8Bit: Bool = false
    ) throws -> MTLTexture {
        try ensureScratch(width: source.width, height: source.height)
        guard let scratchA, let scratchB, let quarter, let momentsA, let momentsB, let baseTexture else {
            throw LapseError.gpuSetupFailed("grade scratch unavailable")
        }

        let usesBase = params.usesBase != 0
        let needsQuarter = usesBase || params.chromaProtect != 0
        var gradeParams = params

        if needsQuarter {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the base prep pass")
            }
            encoder.setTexture(source, index: 0)
            encoder.setTexture(quarter, index: 1)
            encoder.setTexture(momentsA, index: 2)
            encoder.setBytes(&gradeParams, length: MemoryLayout<GPUGradeParams>.stride, index: 0)
            core.dispatch(core.basePrepPipeline, encoder: encoder, width: quarter.width, height: quarter.height)
            encoder.endEncoding()
        }

        if usesBase {
            // Guided filter over the quarter-res log-luma: Gaussian means of
            // the moments, coefficients, Gaussian means of the coefficients,
            // resolve. Sigma follows the image so a preview and an export get
            // the same look.
            let longEdge = Float(max(quarter.width, quarter.height))
            let sigma = max(longEdge * 0.025, 1)
            var blurParams = GPUBlurParams(
                sigma: sigma,
                radius: Int32(min(max(Int(sigma * 2.5), 1), 128)))
            var guidedParams = GPUGuidedParams(epsilon: ToneMath.guidedFilterEpsilon)

            func blurPair(from: MTLTexture, via: MTLTexture) throws {
                guard let horizontal = commandBuffer.makeComputeCommandEncoder() else {
                    throw LapseError.gpuSetupFailed("could not encode the base blur")
                }
                horizontal.setTexture(from, index: 0)
                horizontal.setTexture(via, index: 1)
                horizontal.setBytes(&blurParams, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
                core.dispatch(core.blurHorizontalPipeline, encoder: horizontal, width: from.width, height: from.height)
                horizontal.endEncoding()

                guard let vertical = commandBuffer.makeComputeCommandEncoder() else {
                    throw LapseError.gpuSetupFailed("could not encode the base blur")
                }
                vertical.setTexture(via, index: 0)
                vertical.setTexture(from, index: 1)
                vertical.setBytes(&blurParams, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
                core.dispatch(core.blurVerticalPipeline, encoder: vertical, width: from.width, height: from.height)
                vertical.endEncoding()
            }

            try blurPair(from: momentsA, via: momentsB)   // momentsA = blurred moments

            guard let abEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the guided coefficients")
            }
            abEncoder.setTexture(momentsA, index: 0)
            abEncoder.setTexture(momentsB, index: 1)
            abEncoder.setBytes(&guidedParams, length: MemoryLayout<GPUGuidedParams>.stride, index: 0)
            core.dispatch(core.guidedABPipeline, encoder: abEncoder, width: momentsA.width, height: momentsA.height)
            abEncoder.endEncoding()

            try blurPair(from: momentsB, via: momentsA)   // momentsB = blurred coefficients

            guard let resolveEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the base resolve")
            }
            resolveEncoder.setTexture(momentsB, index: 0)
            resolveEncoder.setTexture(quarter, index: 1)
            resolveEncoder.setTexture(baseTexture, index: 2)
            core.dispatch(core.guidedResolvePipeline, encoder: resolveEncoder, width: baseTexture.width, height: baseTexture.height)
            resolveEncoder.endEncoding()
        }

        guard let toneEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode the tone pass")
        }
        toneEncoder.setTexture(source, index: 0)
        toneEncoder.setTexture(scratchA, index: 1)
        toneEncoder.setTexture(baseTexture, index: 2)
        toneEncoder.setTexture(quarter, index: 3)
        toneEncoder.setBytes(&gradeParams, length: MemoryLayout<GPUGradeParams>.stride, index: 0)
        lut.withUnsafeBufferPointer { buffer in
            toneEncoder.setBytes(buffer.baseAddress!, length: buffer.count * MemoryLayout<Float>.stride, index: 1)
        }
        core.dispatch(core.gradeTonePipeline, encoder: toneEncoder, width: source.width, height: source.height)
        toneEncoder.endEncoding()
        var current = scratchA
        var spare = scratchB

        if recipe.texture != 0, let halfLumaA, let halfLumaB {
            // Mid-frequency band: blur half-res encoded luma at sigma
            // proportional to the image, then add the tanh-limited residual.
            let halfLong = Float(max(halfLumaA.width, halfLumaA.height))
            let sigma = max(halfLong * ToneMath.textureSigmaFraction, 1)
            var blurParams = GPUBlurParams(
                sigma: sigma,
                radius: Int32(min(max(Int(sigma * 2.5), 1), 128)))
            var textureParams = GPUDetailParams(
                amount: ToneMath.textureStrength * recipe.texture,
                tau: ToneMath.textureTau,
                sigma: sigma,
                radius: blurParams.radius)

            guard let lumaEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the texture luma pass")
            }
            lumaEncoder.setTexture(current, index: 0)
            lumaEncoder.setTexture(halfLumaA, index: 1)
            core.dispatch(core.detailLumaPipeline, encoder: lumaEncoder, width: halfLumaA.width, height: halfLumaA.height)
            lumaEncoder.endEncoding()

            guard let horizontal = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the texture blur")
            }
            horizontal.setTexture(halfLumaA, index: 0)
            horizontal.setTexture(halfLumaB, index: 1)
            horizontal.setBytes(&blurParams, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
            core.dispatch(core.blurHorizontalPipeline, encoder: horizontal, width: halfLumaA.width, height: halfLumaA.height)
            horizontal.endEncoding()

            guard let vertical = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the texture blur")
            }
            vertical.setTexture(halfLumaB, index: 0)
            vertical.setTexture(halfLumaA, index: 1)
            vertical.setBytes(&blurParams, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
            core.dispatch(core.blurVerticalPipeline, encoder: vertical, width: halfLumaA.width, height: halfLumaA.height)
            vertical.endEncoding()

            guard let applyEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the texture apply")
            }
            applyEncoder.setTexture(current, index: 0)
            applyEncoder.setTexture(halfLumaA, index: 1)
            applyEncoder.setTexture(spare, index: 2)
            applyEncoder.setBytes(&textureParams, length: MemoryLayout<GPUDetailParams>.stride, index: 0)
            core.dispatch(core.textureApplyPipeline, encoder: applyEncoder, width: source.width, height: source.height)
            applyEncoder.endEncoding()
            swap(&current, &spare)
        }

        if recipe.sharpen > 0 {
            // Capture sharpen: inline small-radius unsharp, resolution-anchored
            // so a preview and an export carry the same acutance.
            let longEdge = Float(max(source.width, source.height))
            let sigma = max(longEdge * ToneMath.sharpenSigmaFraction, 0.4)
            var sharpenParams = GPUDetailParams(
                amount: ToneMath.sharpenStrength * recipe.sharpen,
                tau: ToneMath.sharpenTau,
                sigma: sigma,
                radius: Int32(min(max(Int((sigma * 2.5).rounded(.up)), 1), 3)))
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the sharpen pass")
            }
            encoder.setTexture(current, index: 0)
            encoder.setTexture(spare, index: 1)
            encoder.setBytes(&sharpenParams, length: MemoryLayout<GPUDetailParams>.stride, index: 0)
            core.dispatch(core.sharpenPipeline, encoder: encoder, width: source.width, height: source.height)
            encoder.endEncoding()
            swap(&current, &spare)
        }

        if recipe.vignette > 0 {
            var vignetteParams = Float(recipe.vignette) * 0.85
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the vignette pass")
            }
            encoder.setTexture(current, index: 0)
            encoder.setTexture(spare, index: 1)
            encoder.setBytes(&vignetteParams, length: MemoryLayout<Float>.stride, index: 0)
            core.dispatch(core.vignettePipeline, encoder: encoder, width: source.width, height: source.height)
            encoder.endEncoding()
            swap(&current, &spare)
        }

        if ditherFor8Bit {
            var ditherParams = GPUDitherParams(amplitude: 1.0 / 255.0, seed: 0x9E37)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the dither pass")
            }
            encoder.setTexture(current, index: 0)
            encoder.setTexture(spare, index: 1)
            encoder.setBytes(&ditherParams, length: MemoryLayout<GPUDitherParams>.stride, index: 0)
            core.dispatch(core.ditherPipeline, encoder: encoder, width: source.width, height: source.height)
            encoder.endEncoding()
            swap(&current, &spare)
        }

        return current
    }

    /// Convenience for one-shot callers (previews, tests): runs `encode` on
    /// the engine's own queue and blocks until the GPU finishes.
    public func apply(to source: MTLTexture, ditherFor8Bit: Bool = false) throws -> MTLTexture {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a grade command buffer")
        }
        let output = try encode(from: source, commandBuffer: commandBuffer, ditherFor8Bit: ditherFor8Bit)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
        }
        return output
    }

    private func ensureScratch(width: Int, height: Int) throws {
        guard width != scratchWidth || height != scratchHeight else { return }
        func make(_ pixelFormat: MTLPixelFormat, _ w: Int, _ h: Int, shared: Bool = false) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = shared ? .shared : .private
            guard let texture = core.device.makeTexture(descriptor: descriptor) else {
                throw LapseError.textureCreationFailed("\(w)x\(h) grade scratch")
            }
            return texture
        }
        // Output scratch is shared so one-shot callers can read results back
        // without an extra blit; the blend path only ever reads it on-GPU.
        scratchA = try make(.rgba16Float, width, height, shared: true)
        scratchB = try make(.rgba16Float, width, height, shared: true)
        // Quarter-res spatial scratch. The moments hold l and l² — l² reaches
        // ~200 and the guided variance is their small difference, so those two
        // are 32-bit float; everything else is fine at half precision.
        let quarterWidth = max(width / 4, 1)
        let quarterHeight = max(height / 4, 1)
        quarter = try make(.rgba16Float, quarterWidth, quarterHeight)
        momentsA = try make(.rg32Float, quarterWidth, quarterHeight)
        momentsB = try make(.rg32Float, quarterWidth, quarterHeight)
        baseTexture = try make(.r16Float, quarterWidth, quarterHeight)
        // Half-res luma pair for the texture band's separable blur.
        let halfWidth = max(width / 2, 1)
        let halfHeight = max(height / 2, 1)
        halfLumaA = try make(.r16Float, halfWidth, halfHeight)
        halfLumaB = try make(.r16Float, halfWidth, halfHeight)
        scratchWidth = width
        scratchHeight = height
    }
}
