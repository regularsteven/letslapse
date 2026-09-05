import Accelerate
import Foundation
import Metal
import MetalPerformanceShaders


extension DNGArchive {
    /// Stage B on the GPU: Malvar-He-Cutler 5×5 demosaic (or 2×2 superpixel
    /// binning) of a 16-bit mosaic into normalised linear RGB, then an optional
    /// Lanczos resample to a target pixel count. iOS-available throughout —
    /// Metal compute plus MPS.
    public final class MetalDemosaic {
        public enum Method: String, CaseIterable, Sendable { case mhc, bin2 }

        public struct Result {
            public let frame: RGBFrame
            public let uploadMilliseconds: Double
            public let demosaicMilliseconds: Double
            public let resizeMilliseconds: Double
            public let readbackMilliseconds: Double
        }

        private let device: MTLDevice
        private let queue: MTLCommandQueue
        var deviceHandle: MTLDevice { device }
        var queueHandle: MTLCommandQueue { queue }
        private let mhc: MTLComputePipelineState
        private let bin: MTLComputePipelineState
        private let gain: MTLComputePipelineState

        public init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw ConversionError.unsupported("no Metal device")
            }
            self.device = device
            self.queue = queue
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let mhcFunction = library.makeFunction(name: "demosaicMHC"),
                  let binFunction = library.makeFunction(name: "superpixel2"),
                  let gainFunction = library.makeFunction(name: "applyGainMap") else {
                throw ConversionError.unsupported("demosaic kernels missing")
            }
            mhc = try device.makeComputePipelineState(function: mhcFunction)
            bin = try device.makeComputePipelineState(function: binFunction)
            gain = try device.makeComputePipelineState(function: gainFunction)
        }

        /// `targetPixels` nil keeps the demosaiced size; otherwise the frame is
        /// Lanczos-resampled to that many pixels (aspect kept).
        /// `gainMaps` (the source's OpcodeList3 GainMaps) are baked into the
        /// result at the final size — their coordinates are normalised, so
        /// the size does not matter.
        public func run(_ mosaic: MosaicFrame, method: Method, targetPixels: Int?, gainMaps: [DNGArchive.GainMap] = []) throws -> Result {
            var clock = ProcessInfo.processInfo.systemUptime
            func lap() -> Double { let now = ProcessInfo.processInfo.systemUptime; defer { clock = now }; return (now - clock) * 1000 }

            let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: mosaic.width, height: mosaic.height, mipmapped: false)
            inputDescriptor.usage = [.shaderRead]
            inputDescriptor.storageMode = .shared
            guard let input = device.makeTexture(descriptor: inputDescriptor) else { throw ConversionError.unsupported("mosaic texture") }
            mosaic.samples.withUnsafeBytes { bytes in
                input.replace(region: MTLRegionMake2D(0, 0, mosaic.width, mosaic.height), mipmapLevel: 0,
                              withBytes: bytes.baseAddress!, bytesPerRow: mosaic.width * 2)
            }
            let upload = lap()

            let outWidth = method == .bin2 ? mosaic.width / 2 : mosaic.width
            let outHeight = method == .bin2 ? mosaic.height / 2 : mosaic.height
            let rgbaDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: outWidth, height: outHeight, mipmapped: false)
            rgbaDescriptor.usage = [.shaderRead, .shaderWrite]
            rgbaDescriptor.storageMode = .shared
            guard let demosaiced = device.makeTexture(descriptor: rgbaDescriptor) else { throw ConversionError.unsupported("rgb texture") }

            var params = Params(
                black: Float(mosaic.black), invRange: Float(1 / (mosaic.white - mosaic.black)),
                pattern: SIMD4<UInt32>(UInt32(mosaic.cfaPattern[0]), UInt32(mosaic.cfaPattern[1]), UInt32(mosaic.cfaPattern[2]), UInt32(mosaic.cfaPattern[3])),
                width: UInt32(mosaic.width), height: UInt32(mosaic.height),
                outWidth: UInt32(outWidth), outHeight: UInt32(outHeight))
            guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw ConversionError.unsupported("command buffer")
            }
            let pipeline = method == .bin2 ? bin : mhc
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(demosaiced, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (outWidth + 15) / 16, height: (outHeight + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw ConversionError.unsupported("demosaic failed: \(error)") }
            let demosaicMs = lap()

            var final = demosaiced
            var finalWidth = outWidth, finalHeight = outHeight
            var resizeMs = 0.0
            if let targetPixels, targetPixels < outWidth * outHeight {
                let scale = (Double(targetPixels) / Double(outWidth * outHeight)).squareRoot()
                finalWidth = Int((Double(outWidth) * scale).rounded())
                finalHeight = Int((Double(outHeight) * scale).rounded())
                let scaledDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: finalWidth, height: finalHeight, mipmapped: false)
                scaledDescriptor.usage = [.shaderRead, .shaderWrite]
                scaledDescriptor.storageMode = .shared
                guard let scaled = device.makeTexture(descriptor: scaledDescriptor) else { throw ConversionError.unsupported("scaled texture") }
                let lanczos = MPSImageLanczosScale(device: device)
                var transform = MPSScaleTransform(scaleX: Double(finalWidth) / Double(outWidth), scaleY: Double(finalHeight) / Double(outHeight), translateX: 0, translateY: 0)
                guard let resizeBuffer = queue.makeCommandBuffer() else { throw ConversionError.unsupported("resize buffer") }
                withUnsafePointer(to: &transform) { lanczos.scaleTransform = $0 }
                lanczos.encode(commandBuffer: resizeBuffer, sourceTexture: demosaiced, destinationTexture: scaled)
                resizeBuffer.commit()
                resizeBuffer.waitUntilCompleted()
                if let error = resizeBuffer.error { throw ConversionError.unsupported("resize failed: \(error)") }
                final = scaled
                resizeMs = lap()
            }

            for map in gainMaps {
                try applyGainMap(map, to: final)
            }

            var rgba = [Float](repeating: 0, count: finalWidth * finalHeight * 4)
            rgba.withUnsafeMutableBytes { bytes in
                final.getBytes(bytes.baseAddress!, bytesPerRow: finalWidth * 16, from: MTLRegionMake2D(0, 0, finalWidth, finalHeight), mipmapLevel: 0)
            }
            var rgb = [Float](repeating: 0, count: finalWidth * finalHeight * 3)
            rgba.withUnsafeMutableBufferPointer { source in
                rgb.withUnsafeMutableBufferPointer { destination in
                    var src = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(finalHeight), width: vImagePixelCount(finalWidth), rowBytes: finalWidth * 16)
                    var dst = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(finalHeight), width: vImagePixelCount(finalWidth), rowBytes: finalWidth * 12)
                    vImageConvert_RGBAFFFFtoRGBFFF(&src, &dst, vImage_Flags(kvImageNoFlags))
                }
            }
            let readback = lap()
            var metadata = mosaic.metadata
            metadata.decodePath += "+metal-\(method.rawValue)" + (targetPixels != nil ? "+lanczos" : "")
            let frame = RGBFrame(width: finalWidth, height: finalHeight, samples: rgb, metadata: metadata)
            return Result(frame: frame, uploadMilliseconds: upload, demosaicMilliseconds: demosaicMs, resizeMilliseconds: resizeMs, readbackMilliseconds: readback)
        }

        private struct GainParams {
            var originV: Float, originH: Float
            var spacingV: Float, spacingH: Float
            var pointsV: UInt32, pointsH: UInt32
            var plane: UInt32, planes: UInt32
            var width: UInt32, height: UInt32
        }

        /// Multiplies `texture` (rgba32Float, in place) by the bilinearly
        /// interpolated gain map. The map lands in a small float texture with
        /// its planes in the colour channels; a single-plane map is replicated.
        /// The opcode's area is taken to be the whole active image, which is
        /// what Apple writes; a partial area would need the rect scaled.
        private func applyGainMap(_ map: DNGArchive.GainMap, to texture: MTLTexture) throws {
            guard map.pointsV > 0, map.pointsH > 0, map.mapPlanes > 0, map.rowPitch == 1, map.colPitch == 1 else {
                throw ConversionError.unsupported("GainMap with pitch \(map.rowPitch)×\(map.colPitch) or an empty grid")
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: map.pointsH, height: map.pointsV, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let mapTexture = device.makeTexture(descriptor: descriptor) else { throw ConversionError.unsupported("gain map texture") }
            var pixels = [Float](repeating: 1, count: map.pointsV * map.pointsH * 4)
            for r in 0..<map.pointsV {
                for c in 0..<map.pointsH {
                    let base = (r * map.pointsH + c) * map.mapPlanes
                    for channel in 0..<3 {
                        let index = map.mapPlanes == 1 ? base : base + min(channel, map.mapPlanes - 1)
                        pixels[(r * map.pointsH + c) * 4 + channel] = map.gains[index]
                    }
                }
            }
            pixels.withUnsafeBytes { bytes in
                mapTexture.replace(region: MTLRegionMake2D(0, 0, map.pointsH, map.pointsV), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: map.pointsH * 16)
            }
            let originV = Float(map.originV)
            let originH = Float(map.originH)
            let spacingV = Float(map.spacingV)
            let spacingH = Float(map.spacingH)
            var params = GainParams(originV: originV, originH: originH, spacingV: spacingV, spacingH: spacingH,
                                    pointsV: UInt32(map.pointsV), pointsH: UInt32(map.pointsH),
                                    plane: UInt32(map.plane), planes: UInt32(map.planes),
                                    width: UInt32(texture.width), height: UInt32(texture.height))
            guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw ConversionError.unsupported("command buffer")
            }
            encoder.setComputePipelineState(gain)
            encoder.setTexture(texture, index: 0)
            encoder.setTexture(mapTexture, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<GainParams>.stride, index: 0)
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (texture.width + 15) / 16, height: (texture.height + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw ConversionError.unsupported("gain map failed: \(error)") }
        }

        private struct Params {
            var black: Float
            var invRange: Float
            var pattern: SIMD4<UInt32>
            var width: UInt32
            var height: UInt32
            var outWidth: UInt32
            var outHeight: UInt32
        }

        static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Params {
            float black;
            float invRange;
            uint4 pattern;
            uint width;
            uint height;
            uint outWidth;
            uint outHeight;
        };

        // Reflect at the borders by an even distance so the CFA phase of the
        // neighbour is preserved (clamping would fold a red site onto a green one).
        inline int reflect(int i, int n) {
            if (i < 0) i = -i;
            if (i >= n) i = 2 * (n - 1) - i;
            return clamp(i, 0, n - 1);
        }

        inline float fetch(texture2d<uint, access::read> t, int x, int y, int w, int h, float black, float invRange) {
            x = reflect(x, w);
            y = reflect(y, h);
            return (float(t.read(uint2(x, y)).r) - black) * invRange;
        }

        inline uint colourAt(constant Params& p, int x, int y) {
            return p.pattern[((y & 1) << 1) | (x & 1)];
        }

        // Malvar, He, Cutler (2004): gradient-corrected bilinear interpolation.
        kernel void demosaicMHC(texture2d<uint, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant Params& p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= p.outWidth || gid.y >= p.outHeight) return;
            int x = gid.x, y = gid.y, w = p.width, h = p.height;
            float v[5][5];
            for (int j = -2; j <= 2; j++)
                for (int i = -2; i <= 2; i++)
                    v[j + 2][i + 2] = fetch(src, x + i, y + j, w, h, p.black, p.invRange);
            float c = v[2][2];
            float cross4 = v[1][2] + v[3][2] + v[2][1] + v[2][3];
            float diag4 = v[1][1] + v[1][3] + v[3][1] + v[3][3];
            float farV = v[0][2] + v[4][2];
            float farH = v[2][0] + v[2][4];
            float far4 = farV + farH;
            float horiz2 = v[2][1] + v[2][3];
            float vert2 = v[1][2] + v[3][2];
            uint colour = colourAt(p, x, y);
            float3 rgb;
            if (colour == 1) {
                uint right = colourAt(p, x + 1, y);
                float estH = (5.0 * c + 4.0 * horiz2 - diag4 + 0.5 * farV - farH) / 8.0;
                float estV = (5.0 * c + 4.0 * vert2 - diag4 + 0.5 * farH - farV) / 8.0;
                rgb = right == 0 ? float3(estH, c, estV) : float3(estV, c, estH);
            } else {
                float g = (4.0 * c + 2.0 * cross4 - far4) / 8.0;
                float other = (6.0 * c + 2.0 * diag4 - 1.5 * far4) / 8.0;
                rgb = colour == 0 ? float3(c, g, other) : float3(other, g, c);
            }
            dst.write(float4(rgb, 1.0), gid);
        }

        struct GainParams {
            float originV, originH;
            float spacingV, spacingH;
            uint pointsV, pointsH;
            uint plane, planes;
            uint width, height;
        };

        // DNG GainMap: the pixel's normalised position → map grid coordinates →
        // bilinear gain per plane, multiplied in place.
        kernel void applyGainMap(texture2d<float, access::read_write> image [[texture(0)]],
                                 texture2d<float, access::read> map [[texture(1)]],
                                 constant GainParams& g [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= g.width || gid.y >= g.height) return;
            float u = (float(gid.x) + 0.5) / float(g.width);
            float v = (float(gid.y) + 0.5) / float(g.height);
            float c = clamp((u - g.originH) / g.spacingH, 0.0, float(g.pointsH - 1));
            float r = clamp((v - g.originV) / g.spacingV, 0.0, float(g.pointsV - 1));
            uint c0 = uint(floor(c)), r0 = uint(floor(r));
            uint c1 = min(c0 + 1, g.pointsH - 1), r1 = min(r0 + 1, g.pointsV - 1);
            float fc = c - float(c0), fr = r - float(r0);
            float4 g00 = map.read(uint2(c0, r0)), g01 = map.read(uint2(c1, r0));
            float4 g10 = map.read(uint2(c0, r1)), g11 = map.read(uint2(c1, r1));
            float4 gain = mix(mix(g00, g01, fc), mix(g10, g11, fc), fr);
            float4 pixel = image.read(gid);
            for (uint p = g.plane; p < min(g.plane + g.planes, 3u); p++) {
                pixel[p] *= gain[p];
            }
            image.write(pixel, gid);
        }

        // 2×2 superpixel: one RGB pixel per Bayer quad, greens averaged.
        kernel void superpixel2(texture2d<uint, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant Params& p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= p.outWidth || gid.y >= p.outHeight) return;
            int x0 = gid.x * 2, y0 = gid.y * 2, w = p.width, h = p.height;
            float sum[3] = {0, 0, 0};
            float count[3] = {0, 0, 0};
            for (int j = 0; j < 2; j++)
                for (int i = 0; i < 2; i++) {
                    uint colour = colourAt(p, x0 + i, y0 + j);
                    sum[colour] += fetch(src, x0 + i, y0 + j, w, h, p.black, p.invRange);
                    count[colour] += 1.0;
                }
            float3 rgb = float3(sum[0] / max(count[0], 1.0), sum[1] / max(count[1], 1.0), sum[2] / max(count[2], 1.0));
            dst.write(float4(rgb, 1.0), gid);
        }
        """
    }



}

extension DNGArchive.MetalDemosaic {
    /// RGBA Float32 in, RGB Float32 out at `targetPixels`.
    func lanczos(rgba: [Float], width: Int, height: Int, targetPixels: Int) throws -> (width: Int, height: Int, rgb: [Float]) {
        let scale = (Double(targetPixels) / Double(width * height)).squareRoot()
        let outWidth = Int((Double(width) * scale).rounded()), outHeight = Int((Double(height) * scale).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let source = deviceHandle.makeTexture(descriptor: descriptor) else { throw DNGArchive.ConversionError.unsupported("source texture") }
        rgba.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: width * 16)
        }
        let scaledDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: outWidth, height: outHeight, mipmapped: false)
        scaledDescriptor.usage = [.shaderRead, .shaderWrite]
        scaledDescriptor.storageMode = .shared
        guard let destination = deviceHandle.makeTexture(descriptor: scaledDescriptor) else { throw DNGArchive.ConversionError.unsupported("scaled texture") }
        let kernel = MPSImageLanczosScale(device: deviceHandle)
        var transform = MPSScaleTransform(scaleX: Double(outWidth) / Double(width), scaleY: Double(outHeight) / Double(height), translateX: 0, translateY: 0)
        guard let commandBuffer = queueHandle.makeCommandBuffer() else { throw DNGArchive.ConversionError.unsupported("command buffer") }
        withUnsafePointer(to: &transform) { kernel.scaleTransform = $0 }
        kernel.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var out = [Float](repeating: 0, count: outWidth * outHeight * 4)
        out.withUnsafeMutableBytes { bytes in
            destination.getBytes(bytes.baseAddress!, bytesPerRow: outWidth * 16, from: MTLRegionMake2D(0, 0, outWidth, outHeight), mipmapLevel: 0)
        }
        var rgb = [Float](repeating: 0, count: outWidth * outHeight * 3)
        out.withUnsafeMutableBufferPointer { s in
            rgb.withUnsafeMutableBufferPointer { d in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(outHeight), width: vImagePixelCount(outWidth), rowBytes: outWidth * 16)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(outHeight), width: vImagePixelCount(outWidth), rowBytes: outWidth * 12)
                vImageConvert_RGBAFFFFtoRGBFFF(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
        return (outWidth, outHeight, rgb)
    }
}

extension DNGArchive.MetalDemosaic {
    public struct ResizeResult {
        public let frame: DNGArchive.RGBFrame
        public let milliseconds: Double
    }

    /// Lanczos resample of an RGB frame on the GPU (for demosaiced inputs).
    public func resize(_ rgb: DNGArchive.RGBFrame, targetPixels: Int) throws -> ResizeResult {
        let started = ProcessInfo.processInfo.systemUptime
        var rgba = [Float](repeating: 0, count: rgb.width * rgb.height * 4)
        rgb.samples.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: vImagePixelCount(rgb.height), width: vImagePixelCount(rgb.width), rowBytes: rgb.width * 12)
                var dst = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(rgb.height), width: vImagePixelCount(rgb.width), rowBytes: rgb.width * 16)
                vImageConvert_RGBFFFtoRGBAFFFF(&src, nil, 1.0, &dst, false, vImage_Flags(kvImageNoFlags))
            }
        }
        let scaled = try lanczos(rgba: rgba, width: rgb.width, height: rgb.height, targetPixels: targetPixels)
        var metadata = rgb.metadata
        metadata.decodePath += "+lanczos"
        return ResizeResult(frame: DNGArchive.RGBFrame(width: scaled.width, height: scaled.height, samples: scaled.rgb, metadata: metadata),
                            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
