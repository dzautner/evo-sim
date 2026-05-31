import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import EvoSimCore

/// Draws each cell as actual cell anatomy: dark membrane outline, mid-tone
/// grainy cytoplasm fill, small bright off-center nucleus. Reads as
/// "microscopy" because that's literally what microscopy looks like.
///
/// Pure 2D z-sorted painter, no SDF, no bin artifacts ever. Background is
/// a pale watery wash with gentle fBm noise. Cells are translucent so
/// stacked cells in 3D show through.
public struct MicroscopyRenderer {
    public var width: Int
    public var height: Int
    /// Cell visual radius in world units. Larger ⇒ cells fill more of the
    /// frame and you can see their nucleus.
    public var cellRadius: Float = 2.4
    /// Membrane thickness as a fraction of the cell radius.
    public var membraneFrac: Float = 0.18
    /// Nucleus radius as a fraction of the cell radius.
    public var nucleusFrac: Float = 0.28
    /// Cytoplasm noise scale (world units).
    public var cytoNoiseScale: Float = 0.6

    public init(width: Int = 480, height: Int = 480) {
        self.width = width
        self.height = height
    }

    @discardableResult
    public func writePNG(_ world: World, to url: URL) -> Bool {
        let pixels = renderRGBA(world)
        return SnapshotRenderer.writeRGBA8PNG(pixels: pixels, width: width, height: height, to: url)
    }

    public func renderRGBA(_ world: World) -> [UInt8] {
        let w = width, h = height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        let bx = world.bounds.x, by = world.bounds.y, bz = world.bounds.z
        let pxPerUnitX = Float(w) / bx
        let pxPerUnitY = Float(h) / by

        // -----------------------------------------------------------------
        // Background: pale watery wash with subtle fBm so it doesn't look
        // like flat plastic. Colour: dim cool blue/grey, like a slide.
        // -----------------------------------------------------------------
        let bgBase = SIMD3<Float>(0.085, 0.105, 0.115)
        let bgWash = SIMD3<Float>(0.115, 0.135, 0.140)
        for py in 0..<h {
            for px in 0..<w {
                let u = Float(px) / Float(w)
                let v = Float(py) / Float(h)
                // Cheap value-noise — large blobby variation across the frame.
                let n1 = Self.valueNoise(u * 4, v * 4, 0x21)
                let n2 = Self.valueNoise(u * 14, v * 14, 0x67) * 0.4
                let n = n1 + n2 - 0.7
                let mix01 = max(0, min(1, 0.4 + n * 0.6))
                let bg = bgBase + (bgWash - bgBase) * mix01
                let idx = 4 * (px + py * w)
                pixels[idx + 0] = toByte(bg.x)
                pixels[idx + 1] = toByte(bg.y)
                pixels[idx + 2] = toByte(bg.z)
                pixels[idx + 3] = 255
            }
        }

        // -----------------------------------------------------------------
        // Z-sort cells back-to-front for proper depth painting.
        // -----------------------------------------------------------------
        var sorted = world.colony.cells
        sorted.sort { $0.position.z < $1.position.z }

        let rPx = cellRadius * pxPerUnitX  // assume square aspect
        let membranePx = rPx * membraneFrac
        let nucleusPx = rPx * nucleusFrac

        for cell in sorted {
            let cxF = cell.position.x * pxPerUnitX
            let cyF = cell.position.y * pxPerUnitY
            // Depth: front cells slightly larger + brighter. zNorm 0 = back.
            let zNorm = max(0, min(1, cell.position.z / bz))
            let depthScale: Float = 0.85 + 0.3 * zNorm
            let depthBright: Float = 0.6 + 0.4 * zNorm
            let r = rPx * depthScale
            let r2 = r * r

            // Per-cell variation: each cell gets a deterministic seed so its
            // membrane noise + nucleus offset are stable frame-to-frame.
            let seedA = UInt32(cell.id &* 374761)
            let seedB = UInt32(cell.id &* 668265)
            let nucleusOffX = (Self.hash01(seedA, 1, 0) - 0.5) * r * 0.35
            let nucleusOffY = (Self.hash01(seedB, 2, 0) - 0.5) * r * 0.35
            let nucleusCx = cxF + nucleusOffX
            let nucleusCy = cyF + nucleusOffY

            // Cytoplasm tone — slight cool/warm by cell.energy.
            let energyHeat = 1.0 - expf(-cell.energy * 0.4)
            let cytoCool = SIMD3<Float>(0.45, 0.52, 0.60)
            let cytoWarm = SIMD3<Float>(0.62, 0.55, 0.45)
            let cytoBase = (cytoCool + (cytoWarm - cytoCool) * energyHeat) * depthBright
            let membraneCol = SIMD3<Float>(0.08, 0.10, 0.13) * depthBright
            let nucleusCol = SIMD3<Float>(0.93, 0.86, 0.74) * depthBright

            // Bounding box.
            let pad = Int(r.rounded(.up)) + 2
            let x0 = max(0, Int(cxF) - pad), x1 = min(w - 1, Int(cxF) + pad)
            let y0 = max(0, Int(cyF) - pad), y1 = min(h - 1, Int(cyF) + pad)
            if x0 > x1 || y0 > y1 { continue }

            // Cytoplasm noise — sample fBm in world coords so it pans with
            // the cell as it moves.
            let cytoSeed = UInt32(cell.id &* 1442695)

            for py in y0...y1 {
                for px in x0...x1 {
                    let dx = Float(px) - cxF
                    let dy = Float(py) - cyF
                    let d2 = dx * dx + dy * dy
                    if d2 > r2 { continue }
                    let d = d2.squareRoot()

                    // Distance to nucleus.
                    let ndx = Float(px) - nucleusCx
                    let ndy = Float(py) - nucleusCy
                    let nd2 = ndx * ndx + ndy * ndy
                    let nd = nd2.squareRoot()

                    // Per-pixel sample colour.
                    var col: SIMD3<Float>
                    var alpha: Float = 0.78  // cells are slightly translucent

                    // Cytoplasm fBm (in world units so it follows the cell).
                    let wx = (Float(px) / pxPerUnitX) / cytoNoiseScale
                    let wy = (Float(py) / pxPerUnitY) / cytoNoiseScale
                    let cytoN = Self.fbm(wx, wy, cytoSeed, octaves: 3)
                    let cytoLit = cytoBase * (0.85 + cytoN * 0.4)

                    if nd < nucleusPx * depthScale {
                        // Inside nucleus — bright with a soft falloff to the
                        // cytoplasm at its edge.
                        let nt = max(0, 1 - nd / (nucleusPx * depthScale))
                        let nGlow = pow(nt, 0.7)
                        col = cytoLit + (nucleusCol - cytoLit) * nGlow
                        alpha = 0.88
                    } else if d > r - membranePx {
                        // Membrane ring — dark with a 1-pixel soft edge so it
                        // doesn't look jagged.
                        let edgeT = max(0, (d - (r - membranePx)) / membranePx)
                        let mGlow = 1 - pow(edgeT, 0.6) * 0.4
                        col = membraneCol * mGlow
                        // Outer membrane fades slightly so cells have a soft
                        // edge against the background.
                        let outerFade = max(0, (d - (r * 0.92)) / (r * 0.08))
                        alpha = 0.95 * (1 - outerFade * 0.45)
                    } else {
                        col = cytoLit
                    }

                    // Composite over background.
                    let idx = 4 * (px + py * w)
                    let bgR = Float(pixels[idx + 0]) / 255
                    let bgG = Float(pixels[idx + 1]) / 255
                    let bgB = Float(pixels[idx + 2]) / 255
                    let outR = bgR * (1 - alpha) + col.x * alpha
                    let outG = bgG * (1 - alpha) + col.y * alpha
                    let outB = bgB * (1 - alpha) + col.z * alpha
                    pixels[idx + 0] = toByte(outR)
                    pixels[idx + 1] = toByte(outG)
                    pixels[idx + 2] = toByte(outB)
                }
            }
        }

        // -----------------------------------------------------------------
        // Final pass: subtle film grain (white noise on luminance) +
        // vignette. Both subtle — the "noise" already comes from the
        // background fBm + cytoplasm fBm + cell membrane edges.
        // -----------------------------------------------------------------
        let cx = Float(w) * 0.5, cy = Float(h) * 0.5
        let maxR = sqrt(cx * cx + cy * cy)
        for py in 0..<h {
            for px in 0..<w {
                let dx = Float(px) - cx
                let dy = Float(py) - cy
                let r01 = sqrt(dx * dx + dy * dy) / maxR
                let vignette: Float = 1 - r01 * r01 * 0.30
                let grain = (Self.hash01(UInt32(px), UInt32(py), 0xAA) - 0.5) * 0.04
                let idx = 4 * (px + py * w)
                let r = Float(pixels[idx + 0]) / 255 * vignette + grain
                let g = Float(pixels[idx + 1]) / 255 * vignette + grain
                let b = Float(pixels[idx + 2]) / 255 * vignette + grain
                pixels[idx + 0] = toByte(r)
                pixels[idx + 1] = toByte(g)
                pixels[idx + 2] = toByte(b)
            }
        }

        return pixels
    }

    // MARK: - helpers (file-private so other renderers can ignore them)

    @inline(__always)
    private func toByte(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, v * 255)))
    }

    @inline(__always)
    static func hash01(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> Float {
        var x = a &+ 0x9E3779B9
        x ^= b &+ 0x85EBCA6B
        x = (x ^ (x >> 16)) &* 0x21F0AAAD
        x = (x ^ (x >> 15)) &* 0x735A2D97
        x ^= c &+ 0xC2B2AE35
        x = (x ^ (x >> 15))
        return Float(x & 0xFFFFFF) / Float(0x1000000)
    }

    static func valueNoise(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        let xi = Int(x.rounded(.down))
        let yi = Int(y.rounded(.down))
        let fx = x - Float(xi)
        let fy = y - Float(yi)
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let a = hash01(UInt32(truncatingIfNeeded: xi &* 374761393),
                       UInt32(truncatingIfNeeded: yi &* 668265263), seed)
        let b = hash01(UInt32(truncatingIfNeeded: (xi + 1) &* 374761393),
                       UInt32(truncatingIfNeeded: yi &* 668265263), seed)
        let c = hash01(UInt32(truncatingIfNeeded: xi &* 374761393),
                       UInt32(truncatingIfNeeded: (yi + 1) &* 668265263), seed)
        let d = hash01(UInt32(truncatingIfNeeded: (xi + 1) &* 374761393),
                       UInt32(truncatingIfNeeded: (yi + 1) &* 668265263), seed)
        let ab = a + (b - a) * sx
        let cd = c + (d - c) * sx
        return ab + (cd - ab) * sy
    }

    static func fbm(_ x: Float, _ y: Float, _ seed: UInt32, octaves: Int = 3) -> Float {
        var total: Float = 0
        var amp: Float = 1
        var freq: Float = 1
        var maxAmp: Float = 0
        for o in 0..<octaves {
            total += (valueNoise(x * freq, y * freq, seed &+ UInt32(o)) - 0.5) * amp
            maxAmp += amp
            amp *= 0.5
            freq *= 2.07
        }
        return total / maxAmp
    }
}
