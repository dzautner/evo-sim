import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import EvoSimCore

/// Phase-1 debug renderer. Projects the 3D nutrient field onto a 2D image by
/// summing along Z (a "microscope" projection), then overlays cells as bright
/// dots. Output is a `width × height` PNG with the pond-water palette: deep
/// blue/black void, amber-yellow nutrient glow, white-hot cell cores.
///
/// This is NOT the final renderer — Phase 6 will replace it with Metal SDF
/// raymarching. It exists so we can generate visible snapshots of the
/// simulation state for tests, screenshots, and CI.
public struct SnapshotRenderer {
    public var width: Int
    public var height: Int
    public var sliceMode: SliceMode
    public var nutrientGain: Float
    public var cellRadiusPx: Float

    public enum SliceMode {
        /// Integrate concentration along the Z axis. Gives an X-ray look.
        case zSum
        /// Sample a single Z-slice through the middle.
        case zMid
    }

    public init(
        width: Int = 720,
        height: Int = 720,
        sliceMode: SliceMode = .zSum,
        nutrientGain: Float = 1.6,
        cellRadiusPx: Float = 9
    ) {
        self.width = width
        self.height = height
        self.sliceMode = sliceMode
        self.nutrientGain = nutrientGain
        self.cellRadiusPx = cellRadiusPx
    }

    /// Render `world` to an RGBA8 buffer. Each pixel = 4 bytes (R,G,B,A).
    public func renderRGBA(_ world: World) -> [UInt8] {
        let w = width, h = height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        // 1. Bake the chemistry projection into an (w×h) intensity buffer.
        var intensity = [Float](repeating: 0, count: w * h)
        let cf = world.chemistry
        let nx = cf.nx, ny = cf.ny, nz = cf.nz

        cf.withConcentration { src in
            @inline(__always)
            func bilinear(_ gx: Float, _ gy: Float, _ k: Int) -> Float {
                let x0 = max(0, min(nx - 1, Int(gx.rounded(.down))))
                let y0 = max(0, min(ny - 1, Int(gy.rounded(.down))))
                let x1 = min(nx - 1, x0 + 1)
                let y1 = min(ny - 1, y0 + 1)
                let fx = gx - Float(x0)
                let fy = gy - Float(y0)
                let kBase = nx * ny * k
                let a = src[x0 + nx * y0 + kBase]
                let b = src[x1 + nx * y0 + kBase]
                let c = src[x0 + nx * y1 + kBase]
                let d = src[x1 + nx * y1 + kBase]
                let ab = a + (b - a) * fx
                let cd = c + (d - c) * fx
                return ab + (cd - ab) * fy
            }

            switch sliceMode {
            case .zSum:
                for py in 0..<h {
                    let gy = Float(py) / Float(h) * Float(ny - 1)
                    for px in 0..<w {
                        let gx = Float(px) / Float(w) * Float(nx - 1)
                        var sum: Float = 0
                        for gz in 0..<nz { sum += bilinear(gx, gy, gz) }
                        intensity[px + py * w] = sum
                    }
                }
            case .zMid:
                let gz = nz / 2
                for py in 0..<h {
                    let gy = Float(py) / Float(h) * Float(ny - 1)
                    for px in 0..<w {
                        let gx = Float(px) / Float(w) * Float(nx - 1)
                        intensity[px + py * w] = bilinear(gx, gy, gz)
                    }
                }
            }
        }

        // 2. Tonemap intensity → pond-water palette → RGBA8.
        //    Reinhard-style x/(1+x) keeps gradient detail inside bright blobs
        //    instead of flat-saturating to one color.
        for n in 0..<(w * h) {
            let v = max(0, intensity[n] * nutrientGain * 0.06)
            let lit = v / (1 + v)
            // Two-stop palette with a midtone for richer interior gradients.
            let r: Float
            let g: Float
            let b: Float
            if lit < 0.5 {
                let t = lit / 0.5
                r = lerp(0.015, 0.55, t)
                g = lerp(0.04, 0.28, t)
                b = lerp(0.09, 0.10, t)
            } else {
                let t = (lit - 0.5) / 0.5
                r = lerp(0.55, 1.0, t)
                g = lerp(0.28, 0.78, t)
                b = lerp(0.10, 0.32, t)
            }
            pixels[4 * n + 0] = toByte(r)
            pixels[4 * n + 1] = toByte(g)
            pixels[4 * n + 2] = toByte(b)
            pixels[4 * n + 3] = 255
        }

        // 3. Overlay cells. Project world.position onto the same XY plane the
        // chemistry uses. Each cell is a soft white-hot dot whose brightness
        // scales with its accumulated energy.
        let worldExtent = SIMD2<Float>(
            Float(nx) * cf.cellSize,
            Float(ny) * cf.cellSize
        )
        let pxPerUnit = SIMD2<Float>(Float(w) / worldExtent.x, Float(h) / worldExtent.y)
        for cell in world.colony.cells {
            let px = cell.position.x * pxPerUnit.x
            let py = cell.position.y * pxPerUnit.y
            let energyHeat = 1.0 - expf(-cell.energy * 0.5)
            let radius = cellRadiusPx + energyHeat * 2.5
            splat(into: &pixels, w: w, h: h, cx: px, cy: py, radius: radius,
                  core: SIMD3<Float>(1.0, 0.95, 0.85),
                  glow: SIMD3<Float>(1.0, 0.55, 0.25),
                  energy: energyHeat)
        }

        return pixels
    }

    /// Render and save PNG. Returns true on success.
    @discardableResult
    public func writePNG(_ world: World, to url: URL) -> Bool {
        let pixels = renderRGBA(world)
        return Self.writeRGBA8PNG(pixels: pixels, width: width, height: height, to: url)
    }

    public static func writeRGBA8PNG(pixels: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        let info: CGBitmapInfo = [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let img = CGImage(
                width: width, height: height,
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: info,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent)
        else { return false }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Helpers

    @inline(__always)
    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    @inline(__always)
    private func toByte(_ x: Float) -> UInt8 {
        UInt8(min(255, max(0, x * 255)))
    }

    private func splat(
        into pixels: inout [UInt8], w: Int, h: Int,
        cx: Float, cy: Float, radius: Float,
        core: SIMD3<Float>, glow: SIMD3<Float>, energy: Float
    ) {
        let r2 = radius * radius
        let pad = Int(radius.rounded(.up)) + 2
        let x0 = max(0, Int(cx) - pad)
        let x1 = min(w - 1, Int(cx) + pad)
        let y0 = max(0, Int(cy) - pad)
        let y1 = min(h - 1, Int(cy) + pad)
        guard x0 <= x1, y0 <= y1 else { return }
        for py in y0...y1 {
            let dy = Float(py) - cy
            for px in x0...x1 {
                let dx = Float(px) - cx
                let d2 = dx * dx + dy * dy
                guard d2 <= r2 * 4 else { continue }
                let d = d2.squareRoot()
                // Hard core then exponential glow falloff.
                let coreA = max(0, 1 - d / radius)
                let glowA = expf(-d / (radius * 0.9)) * 0.6 * (0.4 + 0.6 * energy)
                let alpha = min(1, coreA + glowA)
                let color = mix(glow, core, t: coreA)
                let n = 4 * (px + py * w)
                let r = Float(pixels[n + 0]) / 255
                let g = Float(pixels[n + 1]) / 255
                let b = Float(pixels[n + 2]) / 255
                let outR = r * (1 - alpha) + color.x * alpha
                let outG = g * (1 - alpha) + color.y * alpha
                let outB = b * (1 - alpha) + color.z * alpha
                pixels[n + 0] = toByte(outR)
                pixels[n + 1] = toByte(outG)
                pixels[n + 2] = toByte(outB)
                pixels[n + 3] = 255
            }
        }
    }

    @inline(__always)
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
