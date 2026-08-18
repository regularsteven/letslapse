import Foundation
import Metal
import simd

/// Compiled pipelines for the tone engine — the grading counterpart of
/// `BlendCore`, built the same way (runtime compile of shipped source).
/// Immutable after init, safe to share.
final class GradeCore: @unchecked Sendable {
    let device: MTLDevice
    let gradeTonePipeline: MTLComputePipelineState
    let clarityLumaPipeline: MTLComputePipelineState
    let blurHorizontalPipeline: MTLComputePipelineState
    let blurVerticalPipeline: MTLComputePipelineState
    let clarityApplyPipeline: MTLComputePipelineState
    let vignettePipeline: MTLComputePipelineState

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
        self.clarityLumaPipeline = try pipeline("clarityLuma")
        self.blurHorizontalPipeline = try pipeline("blurHorizontal")
        self.blurVerticalPipeline = try pipeline("blurVertical")
        self.clarityApplyPipeline = try pipeline("clarityApply")
        self.vignettePipeline = try pipeline("applyVignette")
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
        var exposureGain: Float
        var kneeK: Float
        var recoveryStrength: Float
        var shadowGain: Float
        var desatCoeff: Float
        var saturationGain: Float
        var vibranceCoeff: Float
        var lutEndSlope: Float
        var lutSize: UInt32
    }

    private struct GPUClarityParams {
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
    private var lumaHalf: MTLTexture?
    private var blurScratch: MTLTexture?
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
        let strength = max(recovery, 0.15)
        let endSlope = (lut[lut.count - 1] - lut[lut.count - 2]) * Float(lut.count - 1)
        return GPUGradeParams(
            wb: ToneMath.whiteBalanceMatrix(recipe: recipe, reference: reference),
            exposureGain: exp2(recipe.exposure),
            kneeK: 0.95 - 0.6 * recovery,
            recoveryStrength: strength,
            shadowGain: 0.9 * recipe.shadows,
            desatCoeff: 0.5 * strength,
            saturationGain: 1 + 0.8 * recipe.saturation,
            vibranceCoeff: 0.9 * recipe.vibrance,
            lutEndSlope: endSlope,
            lutSize: UInt32(lut.count))
    }

    /// Encodes the whole grade into `commandBuffer` and returns the output
    /// texture (renderer-owned scratch, valid until the next `encode` call).
    /// Input: scene-linear Display P3, rgba16Float. Output: display-referred
    /// [0,1] linear, same primaries, rgba16Float.
    public func encode(from source: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try ensureScratch(width: source.width, height: source.height)
        guard let scratchA, let scratchB else {
            throw LapseError.gpuSetupFailed("grade scratch unavailable")
        }

        guard let toneEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode the tone pass")
        }
        var gradeParams = params
        toneEncoder.setTexture(source, index: 0)
        toneEncoder.setTexture(scratchA, index: 1)
        toneEncoder.setBytes(&gradeParams, length: MemoryLayout<GPUGradeParams>.stride, index: 0)
        lut.withUnsafeBufferPointer { buffer in
            toneEncoder.setBytes(buffer.baseAddress!, length: buffer.count * MemoryLayout<Float>.stride, index: 1)
        }
        core.dispatch(core.gradeTonePipeline, encoder: toneEncoder, width: source.width, height: source.height)
        toneEncoder.endEncoding()
        var current = scratchA
        var spare = scratchB

        if recipe.clarity > 0, let lumaHalf, let blurScratch {
            // Base = Gaussian blur of half-res encoded luma; sigma follows the
            // image so a preview and an export get the same look.
            let sigma = max(Float(max(source.width, source.height)) * 0.02 * 0.5, 1)
            var clarityParams = GPUClarityParams(
                amount: 0.8 * recipe.clarity,
                tau: 0.15,
                sigma: sigma,
                radius: Int32(min(max(Int(sigma * 2.5), 1), 128)))

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the clarity pass")
            }
            encoder.setTexture(current, index: 0)
            encoder.setTexture(lumaHalf, index: 1)
            core.dispatch(core.clarityLumaPipeline, encoder: encoder, width: lumaHalf.width, height: lumaHalf.height)
            encoder.endEncoding()

            guard let blurEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the clarity blur")
            }
            blurEncoder.setTexture(lumaHalf, index: 0)
            blurEncoder.setTexture(blurScratch, index: 1)
            blurEncoder.setBytes(&clarityParams, length: MemoryLayout<GPUClarityParams>.stride, index: 0)
            core.dispatch(core.blurHorizontalPipeline, encoder: blurEncoder, width: lumaHalf.width, height: lumaHalf.height)
            blurEncoder.endEncoding()

            guard let blurEncoder2 = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the clarity blur")
            }
            blurEncoder2.setTexture(blurScratch, index: 0)
            blurEncoder2.setTexture(lumaHalf, index: 1)
            blurEncoder2.setBytes(&clarityParams, length: MemoryLayout<GPUClarityParams>.stride, index: 0)
            core.dispatch(core.blurVerticalPipeline, encoder: blurEncoder2, width: lumaHalf.width, height: lumaHalf.height)
            blurEncoder2.endEncoding()

            guard let applyEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw LapseError.gpuSetupFailed("could not encode the clarity apply")
            }
            applyEncoder.setTexture(current, index: 0)
            applyEncoder.setTexture(lumaHalf, index: 1)
            applyEncoder.setTexture(spare, index: 2)
            applyEncoder.setBytes(&clarityParams, length: MemoryLayout<GPUClarityParams>.stride, index: 0)
            core.dispatch(core.clarityApplyPipeline, encoder: applyEncoder, width: source.width, height: source.height)
            applyEncoder.endEncoding()
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

        return current
    }

    /// Convenience for one-shot callers (previews, tests): runs `encode` on
    /// the engine's own queue and blocks until the GPU finishes.
    public func apply(to source: MTLTexture) throws -> MTLTexture {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a grade command buffer")
        }
        let output = try encode(from: source, commandBuffer: commandBuffer)
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
        let halfWidth = max(width / 2, 1)
        let halfHeight = max(height / 2, 1)
        lumaHalf = try make(.r16Float, halfWidth, halfHeight)
        blurScratch = try make(.r16Float, halfWidth, halfHeight)
        scratchWidth = width
        scratchHeight = height
    }
}
