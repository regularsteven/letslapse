import Foundation
import Metal
import CoreVideo
import simd

/// Shared Metal state for all blending work: device, command queue, compiled
/// kernels, and a CoreVideo texture cache for zero-copy CVPixelBuffer access.
/// Immutable after init, safe to share across threads.
public final class BlendCore: @unchecked Sendable {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let clearPipeline: MTLComputePipelineState
    let accumulatePipeline: MTLComputePipelineState
    let finalizePipeline: MTLComputePipelineState
    let finalizeMeanPipeline: MTLComputePipelineState
    let encodeGammaPipeline: MTLComputePipelineState
    let accumulateYUVPipeline: MTLComputePipelineState
    let chromaSampler: MTLSamplerState
    let textureCache: CVMetalTextureCache

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw LapseError.metalUnavailable
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw LapseError.gpuSetupFailed("could not create a command queue")
        }
        self.commandQueue = queue

        let library = try BlendCore.makeLibrary(device: device)
        self.clearPipeline = try BlendCore.makePipeline(library: library, function: "clearAccumulator")
        self.accumulatePipeline = try BlendCore.makePipeline(library: library, function: "accumulateFrame")
        self.finalizePipeline = try BlendCore.makePipeline(library: library, function: "finalizeAverage")
        self.finalizeMeanPipeline = try BlendCore.makePipeline(library: library, function: "finalizeMeanLinear")
        self.encodeGammaPipeline = try BlendCore.makePipeline(library: library, function: "encodeGamma")
        self.accumulateYUVPipeline = try BlendCore.makePipeline(library: library, function: "accumulateFrameYUV")

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw LapseError.gpuSetupFailed("could not create the chroma sampler")
        }
        self.chromaSampler = sampler

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else {
            throw LapseError.gpuSetupFailed("could not create a CoreVideo Metal texture cache")
        }
        self.textureCache = cache
    }

    // The kernel ships as source and compiles at runtime: SwiftPM's metallib
    // handling differs between `swift build` and Xcode, but source + runtime
    // compile behaves identically everywhere and costs milliseconds once.
    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = bundledKernelSource() ?? embeddedKernelSource
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw LapseError.gpuSetupFailed("kernel compilation failed: \(error.localizedDescription)")
        }
    }

    /// The bundled copy of the kernel source. Internal so the test suite can
    /// assert it never drifts from `embeddedKernelSource` — the two are
    /// hand-maintained twins.
    static func bundledKernelSource() -> String? {
        let url = Bundle.module.url(
            forResource: "BlendKernels",
            withExtension: "metal",
            subdirectory: "Metal"
        ) ?? Bundle.module.url(forResource: "BlendKernels", withExtension: "metal")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func makePipeline(library: MTLLibrary, function name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw LapseError.gpuSetupFailed("missing kernel function \(name)")
        }
        do {
            return try library.device.makeComputePipelineState(function: function)
        } catch {
            throw LapseError.gpuSetupFailed("pipeline for \(name) failed: \(error.localizedDescription)")
        }
    }

    func makeAccumulatorTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) rgba32Float accumulator")
        }
        return texture
    }

    /// A half-float destination for `finalizeMeanLinear` — the window's mean
    /// at full precision, before `encodeGamma` quantizes it exactly once.
    func makeMeanTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) rgba16Float mean")
        }
        return texture
    }

    /// Mirror of the Metal `EncodeParams` struct — layouts must match.
    struct EncodeParams {
        var gamut: simd_float3x3
        var ditherLSB: Float
        var frameIndex: UInt32
        var applySRGB: UInt32
    }

    /// Transfer-encode `source` into `destination` with triangular-PDF dither
    /// (and, when `gamut` isn't identity, a linear-domain primaries
    /// conversion first). `destination` must be a non-sRGB view — the curve
    /// is applied in-kernel.
    func encodeGamma(
        from source: MTLTexture,
        to destination: MTLTexture,
        ditherLSB: Float,
        frameIndex: Int,
        applySRGB: Bool,
        gamut: simd_float3x3 = matrix_identity_float3x3,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode gamma pass")
        }
        var params = EncodeParams(
            gamut: gamut,
            ditherLSB: ditherLSB,
            frameIndex: UInt32(truncatingIfNeeded: frameIndex),
            applySRGB: applySRGB ? 1 : 0)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<EncodeParams>.stride, index: 0)
        dispatch(encodeGammaPipeline, encoder: encoder, width: destination.width, height: destination.height)
        encoder.endEncoding()
    }

    /// Wraps a CVPixelBuffer as a Metal texture — BGRA at 8 bits, or RGBA
    /// half-float for the 10-bit encode path's `64RGBAHalf` pool buffers. The
    /// returned holder must stay alive until GPU work reading the texture has
    /// completed.
    func makeTexture(from pixelBuffer: CVPixelBuffer, srgb: Bool) throws -> (texture: MTLTexture, holder: CVMetalTexture) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format: MTLPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf
            ? .rgba16Float
            : (srgb ? .bgra8Unorm_srgb : .bgra8Unorm)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, format, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw LapseError.textureCreationFailed("CVPixelBuffer wrap failed (status \(status))")
        }
        return (texture, cvTexture)
    }

    /// Mirror of the Metal `YUVParams` struct — layouts must match.
    struct YUVParams {
        var matrix: simd_float3x3
        var lumaOffset: Float
        var chromaOffset: Float
        var lumaScale: Float
        var chromaScale: Float
        var toLinear: UInt32
    }

    /// The conversion a decoded biplanar buffer needs, read from the buffer's
    /// own attachments rather than assumed. Returns nil for anything that is
    /// not 8-bit biplanar 4:2:0, so the caller can stay on the BGRA path.
    static func yuvParams(for pixelBuffer: CVPixelBuffer, toLinear: Bool) -> YUVParams? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fullRange: Bool
        let deep: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: (fullRange, deep) = (false, false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: (fullRange, deep) = (true, false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: (fullRange, deep) = (false, true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: (fullRange, deep) = (true, true)
        default: return nil
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return nil }

        // Luma coefficients per the buffer's tagged matrix; 709 is the default
        // for everything this app records.
        let matrixTag = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)?
            .takeUnretainedValue() as? String
        let kr: Float
        let kb: Float
        switch matrixTag as CFString? {
        case kCVImageBufferYCbCrMatrix_ITU_R_601_4: (kr, kb) = (0.299, 0.114)
        case kCVImageBufferYCbCrMatrix_ITU_R_2020: (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.2126, 0.0722)   // ITU_R_709_2
        }
        let kg = 1 - kr - kb
        let rCr = 2 * (1 - kr)
        let bCb = 2 * (1 - kb)
        let gCb = -bCb * kb / kg
        let gCr = -rCr * kr / kg
        // simd is column-major: column 0 scales Y, column 1 Cb, column 2 Cr.
        let matrix = simd_float3x3(columns: (
            SIMD3<Float>(1, 1, 1),
            SIMD3<Float>(0, gCb, bCb),
            SIMD3<Float>(rCr, gCr, 0)))

        // 10-bit biplanar ('x420') stores each sample left-aligned in a 16-bit
        // word — measured exactly x256 against the same frame read as 8-bit —
        // so an r16Unorm read yields code * 64 / 65535 rather than code / 1023.
        // Folding that into the offsets and scales keeps the kernel identical
        // for both depths.
        let unit: Float = deep ? 64.0 / 65535.0 : 1.0 / 255.0
        let black: Float = deep ? 64 : 16
        let lumaTop: Float = deep ? 940 : 235
        let chromaTop: Float = deep ? 960 : 240
        let middle: Float = deep ? 512 : 128
        let peak: Float = deep ? 1023 : 255
        return YUVParams(
            matrix: matrix,
            lumaOffset: fullRange ? 0 : black * unit,
            chromaOffset: middle * unit,
            lumaScale: fullRange
                ? 1 / (peak * unit)
                : 1 / ((lumaTop - black) * unit),
            chromaScale: fullRange
                ? 1 / (peak * unit)
                : 1 / ((chromaTop - black) * unit),
            toLinear: toLinear ? 1 : 0)
    }

    /// Wraps a biplanar buffer's two planes as Metal textures. Both holders
    /// must stay alive until the GPU work reading them has completed.
    func makeYUVTextures(
        from pixelBuffer: CVPixelBuffer
    ) throws -> (luma: MTLTexture, chroma: MTLTexture, holders: [CVMetalTexture]) {
        func plane(_ index: Int, _ format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                format, width, height, index, &cvTexture)
            guard status == kCVReturnSuccess, let cvTexture,
                  let texture = CVMetalTextureGetTexture(cvTexture) else {
                throw LapseError.textureCreationFailed("plane \(index) wrap failed (status \(status))")
            }
            return (texture, cvTexture)
        }
        let deep = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ].contains(CVPixelBufferGetPixelFormatType(pixelBuffer))
        let (luma, lumaHolder) = try plane(0, deep ? .r16Unorm : .r8Unorm)
        let (chroma, chromaHolder) = try plane(1, deep ? .rg16Unorm : .rg8Unorm)
        return (luma, chroma, [lumaHolder, chromaHolder])
    }

    func dispatch(_ pipeline: MTLComputePipelineState, encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    static let embeddedKernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    // The blend engine's entire GPU surface: sum a window of frames into a
    // float32 accumulator, then divide by the frame count. Written once, shared
    // by iOS, iPadOS, and macOS.

    kernel void clearAccumulator(
        texture2d<float, access::write> accumulator [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) {
            return;
        }
        accumulator.write(float4(0.0), gid);
    }

    kernel void accumulateFrame(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::read_write> accumulator [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) {
            return;
        }
        accumulator.write(accumulator.read(gid) + source.read(gid), gid);
    }

    kernel void finalizeAverage(
        texture2d<float, access::read> accumulator [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant float &frameCount [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        float4 mean = accumulator.read(gid) / max(frameCount, 1.0);
        destination.write(float4(mean.rgb, 1.0), gid);
    }

    // The high-precision finalize pair: the mean lands in a float destination
    // untouched, and `encodeGamma` is the pipeline's single quantization point —
    // transfer curve plus triangular-PDF dither, so smooth gradients quantize to
    // noise instead of contours.

    struct EncodeParams {
        float3x3 gamut;     // linear-domain primaries conversion; identity = none
        float ditherLSB;    // 1/255 for 8-bit targets, 0 for 10-bit and wider
        uint  frameIndex;   // reseeds the dither per output frame
        uint  applySRGB;    // 1 = encode linear -> sRGB here, 0 = store verbatim
    };

    static inline uint hashPCG(uint x)
    {
        x ^= x >> 16; x *= 0x7feb352dU;
        x ^= x >> 15; x *= 0x846ca68bU;
        x ^= x >> 16;
        return x;
    }

    static inline float ditherNoise(uint2 gid, uint seed)
    {
        uint h = hashPCG(gid.x * 1973u ^ gid.y * 9277u ^ seed * 26699u);
        return float(h) / 4294967295.0;
    }

    static inline float linearToSRGB(float x)
    {
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
    }

    kernel void finalizeMeanLinear(
        texture2d<float, access::read> accumulator [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant float &frameCount [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        float4 mean = accumulator.read(gid) / max(frameCount, 1.0);
        destination.write(float4(mean.rgb, 1.0), gid);
    }

    // The destination view must be a non-sRGB format: the transfer curve is
    // applied in-kernel, never by the hardware store.
    kernel void encodeGamma(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant EncodeParams &params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        float3 value = clamp(params.gamut * source.read(gid).rgb, 0.0, 1.0);
        if (params.applySRGB != 0) {
            value = float3(linearToSRGB(value.r), linearToSRGB(value.g), linearToSRGB(value.b));
        }
        if (params.ditherLSB > 0.0) {
            uint base = params.frameIndex * 3u;
            for (uint c = 0; c < 3; c++) {
                float noise = ditherNoise(gid, base + c)
                            + ditherNoise(gid, (base + c) ^ 0x9E3779B9u) - 1.0;
                value[c] += noise * params.ditherLSB;
            }
        }
        destination.write(float4(clamp(value, 0.0, 1.0), 1.0), gid);
    }

    // The native-YUV accumulate path. Asking the reader for 32BGRA makes
    // VideoToolbox convert every frame, and that conversion — not the decode —
    // is what bounds a blend render (measured 212 fps to BGRA vs 481 fps native
    // on the same 12 MP HEVC clip, same single thread). Reading the decoder's own
    // biplanar output and converting here costs the GPU almost nothing, and moves
    // a quarter as many bytes.

    struct YUVParams {
        float3x3 matrix;    // (Y,Cb,Cr) -> (R,G,B), full-range coefficients
        float lumaOffset;   // subtracted from Y before scaling
        float chromaOffset; // subtracted from Cb/Cr before scaling
        float lumaScale;    // video-range expansion for Y
        float chromaScale;  // video-range expansion for Cb/Cr
        uint  toLinear;     // 1 = decode sRGB -> linear light, matching the
                            // bgra8Unorm_srgb texture view the BGRA path relied on
    };

    static inline float srgbToLinear(float x)
    {
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
    }

    kernel void accumulateFrameYUV(
        texture2d<float, access::read> luma [[texture(0)]],
        texture2d<float> chroma [[texture(1)]],
        texture2d<float, access::read_write> accumulator [[texture(2)]],
        constant YUVParams &params [[buffer(0)]],
        sampler chromaSampler [[sampler(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint width = accumulator.get_width();
        uint height = accumulator.get_height();
        if (gid.x >= width || gid.y >= height) {
            return;
        }
        // Chroma is half resolution; sampling it bilinearly at the luma pixel
        // centre reproduces the decoder's own upsampling closely enough that the
        // difference disappears into the window average.
        float2 centre = (float2(gid) + 0.5) / float2(width, height);
        float y = luma.read(gid).r;
        float2 cbcr = chroma.sample(chromaSampler, centre).rg;
        float3 ycc = float3(
            (y - params.lumaOffset) * params.lumaScale,
            (cbcr.x - params.chromaOffset) * params.chromaScale,
            (cbcr.y - params.chromaOffset) * params.chromaScale);
        // Clamped before the transfer curve because the 8-bit BGRA buffer this
        // replaces was clamped by the conversion that wrote it.
        float3 rgb = clamp(params.matrix * ycc, 0.0, 1.0);
        if (params.toLinear != 0) {
            rgb = float3(srgbToLinear(rgb.r), srgbToLinear(rgb.g), srgbToLinear(rgb.b));
        }
        accumulator.write(accumulator.read(gid) + float4(rgb, 1.0), gid);
    }
    """
}
