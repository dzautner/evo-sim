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
    /// When true, the camera frames the largest organism (by cell count)
    /// plus padding, so the rendered image is creature-centric rather than
    /// tank-overview. When false, the whole tank is shown.
    public var followLargestOrganism: Bool = false
    /// Padding around the followed organism, in world units.
    public var followPadding: Float = 6.0
    /// Minimum framed extent in world units (avoid extreme zoom on a
    /// single-cell organism).
    public var minFrameExtent: Float = 14.0

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

        // Camera viewport: either full tank, or a tight frame around the
        // largest organism. viewMinX/Y, viewExtentX/Y are in world units.
        var viewMinX: Float = 0, viewMinY: Float = 0
        var viewExtentX: Float = bx, viewExtentY: Float = by
        if followLargestOrganism, !world.colony.cells.isEmpty {
            // Count cells per organism, pick the most populous.
            var counts: [UInt32: Int] = [:]
            for c in world.colony.cells {
                counts[c.organismId, default: 0] += 1
            }
            if let (bestOid, _) = counts.max(by: { $0.value < $1.value }) {
                var minP = SIMD2<Float>( Float.greatestFiniteMagnitude,  Float.greatestFiniteMagnitude)
                var maxP = SIMD2<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
                for c in world.colony.cells where c.organismId == bestOid {
                    minP.x = min(minP.x, c.position.x)
                    minP.y = min(minP.y, c.position.y)
                    maxP.x = max(maxP.x, c.position.x)
                    maxP.y = max(maxP.y, c.position.y)
                }
                // Pad + enforce minimum extent + square aspect.
                var extentX = (maxP.x - minP.x) + followPadding * 2
                var extentY = (maxP.y - minP.y) + followPadding * 2
                let side = max(minFrameExtent, max(extentX, extentY))
                extentX = side; extentY = side
                let cx = (minP.x + maxP.x) * 0.5
                let cy = (minP.y + maxP.y) * 0.5
                viewMinX = cx - extentX * 0.5
                viewMinY = cy - extentY * 0.5
                viewExtentX = extentX
                viewExtentY = extentY
            }
        }
        let pxPerUnitX = Float(w) / viewExtentX
        let pxPerUnitY = Float(h) / viewExtentY
        @inline(__always) func wx2px(_ wx: Float) -> Float { (wx - viewMinX) * pxPerUnitX }
        @inline(__always) func wy2py(_ wy: Float) -> Float { (wy - viewMinY) * pxPerUnitY }

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
        // Cytoplasmic bridges between bonded cells — drawn first so cells
        // render on top of them. Each bond becomes a thin tapered link in
        // the slide background tone of a membrane.
        // -----------------------------------------------------------------
        var posById = [UInt32: SIMD2<Float>]()
        posById.reserveCapacity(world.colony.cells.count)
        for c in world.colony.cells {
            posById[c.id] = SIMD2<Float>(wx2px(c.position.x), wy2py(c.position.y))
        }
        for bond in world.colony.bonds {
            guard let pa = posById[bond.a], let pb = posById[bond.b] else { continue }
            drawCytoBridge(into: &pixels, w: w, h: h, a: pa, b: pb,
                           color: SIMD3<Float>(0.36, 0.42, 0.46),
                           halfWidth: 1.6)
        }

        // -----------------------------------------------------------------
        // Z-sort cells back-to-front for proper depth painting.
        // -----------------------------------------------------------------
        var sorted = world.colony.cells
        sorted.sort { $0.position.z < $1.position.z }

        let baseRPx = cellRadius * pxPerUnitX  // assume square aspect

        // Build cell index → role signals so cytoplasm tone can shift
        // subtly by NCA output (predator = warmer, motor = neutral,
        // structural = cooler).
        var roleP = [UInt32: Float]()
        var roleC = [UInt32: Float]()
        for (i, c) in world.colony.cells.enumerated() {
            roleP[c.id] = world.colony.predation.indices.contains(i) ? max(0, world.colony.predation[i]) : 0
            roleC[c.id] = world.colony.contraction.indices.contains(i) ? max(0, world.colony.contraction[i]) : 0
        }

        for cell in sorted {
            // Per-cell visual seed for stable membrane shape / nucleus offset.
            let seedCore = UInt32(cell.id)
            // Cell size varies with cumulative energy + a small per-cell
            // genetic factor.
            let energyHeat = 1.0 - expf(-cell.energy * 0.4)
            let sizeJitter = 0.85 + Self.hash01(seedCore, 11, 0) * 0.4
            let rPx = baseRPx * sizeJitter * (0.85 + 0.25 * energyHeat)
            let membranePx = rPx * membraneFrac
            let nucleusPx = rPx * nucleusFrac
            // Second internal structure (vacuole/organelle): smaller, dimmer,
            // farther offset than nucleus.
            let vacRadiusPx = rPx * 0.16
            let vacOffMag = rPx * 0.45
            let cxF = wx2px(cell.position.x)
            let cyF = wy2py(cell.position.y)
            // Depth: front cells slightly larger + brighter. zNorm 0 = back.
            let zNorm = max(0, min(1, cell.position.z / bz))
            let depthScale: Float = 0.85 + 0.3 * zNorm
            let depthBright: Float = 0.6 + 0.4 * zNorm
            let r = rPx * depthScale
            let r2 = r * r

            // Per-cell variation: each cell gets a deterministic seed so its
            // membrane noise + nucleus offset are stable frame-to-frame.
            let seedA = UInt32(truncatingIfNeeded: Int(cell.id) &* 374761)
            let seedB = UInt32(truncatingIfNeeded: Int(cell.id) &* 668265)
            let seedC = UInt32(truncatingIfNeeded: Int(cell.id) &* 2147483)
            let seedD = UInt32(truncatingIfNeeded: Int(cell.id) &* 9176881)
            let nucleusOffX = (Self.hash01(seedA, 1, 0) - 0.5) * r * 0.35
            let nucleusOffY = (Self.hash01(seedB, 2, 0) - 0.5) * r * 0.35
            let nucleusCx = cxF + nucleusOffX
            let nucleusCy = cyF + nucleusOffY
            // Vacuole offset — opposite side of nucleus, jittered.
            let vacAngle = Self.hash01(seedC, 3, 0) * 6.2831
            let vacCx = cxF + cos(vacAngle) * vacOffMag * depthScale
            let vacCy = cyF + sin(vacAngle) * vacOffMag * depthScale

            // Cytoplasm tone — base cool/warm shifts by role signals.
            let pSig = roleP[cell.id] ?? 0
            let mSig = roleC[cell.id] ?? 0
            let cytoStruct = SIMD3<Float>(0.42, 0.50, 0.58)   // structural: cool
            let cytoMotor = SIMD3<Float>(0.55, 0.51, 0.45)    // motor: neutral
            let cytoPred = SIMD3<Float>(0.60, 0.42, 0.40)     // predator: warm/reddish
            var cytoBase: SIMD3<Float>
            if pSig > 0.25 {
                cytoBase = mix(cytoStruct, cytoPred, t: min(1, pSig * 1.8))
            } else if mSig > 0.25 {
                cytoBase = mix(cytoStruct, cytoMotor, t: min(1, mSig * 1.8))
            } else {
                cytoBase = cytoStruct
            }
            cytoBase = cytoBase * depthBright * (0.9 + 0.2 * energyHeat)
            let membraneCol = SIMD3<Float>(0.07, 0.08, 0.11) * depthBright
            let nucleusCol = SIMD3<Float>(0.93, 0.86, 0.74) * depthBright
            let vacuoleCol = SIMD3<Float>(0.25, 0.28, 0.32) * depthBright

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
                    if d2 > r2 * 1.15 { continue }  // pre-cull
                    let d = d2.squareRoot()

                    // Per-pixel membrane-radius modulation: sample angular
                    // fBm so the cell outline isn't a perfect circle. Real
                    // cells aren't perfectly round.
                    let theta = atan2f(dy, dx)
                    let lobe = Self.valueNoise(theta * 1.3 + 7.0, theta * 0.7, seedD) - 0.5
                    let lobe2 = Self.valueNoise(theta * 2.7, theta * 1.5 + 3.1, seedC) - 0.5
                    let radiusMod = r * (1.0 + (lobe * 0.10 + lobe2 * 0.06))
                    if d > radiusMod { continue }

                    // Distance to nucleus.
                    let ndx = Float(px) - nucleusCx
                    let ndy = Float(py) - nucleusCy
                    let nd2 = ndx * ndx + ndy * ndy
                    let nd = nd2.squareRoot()
                    let vdx = Float(px) - vacCx
                    let vdy = Float(py) - vacCy
                    let vd2 = vdx * vdx + vdy * vdy
                    let vd = vd2.squareRoot()

                    var col: SIMD3<Float>
                    var alpha: Float = 0.82

                    // Cytoplasm fBm in true world coords (respects viewport).
                    let wx = (viewMinX + Float(px) / pxPerUnitX) / cytoNoiseScale
                    let wy = (viewMinY + Float(py) / pxPerUnitY) / cytoNoiseScale
                    let cytoN = Self.fbm(wx, wy, cytoSeed, octaves: 3)
                    let cytoLit = cytoBase * (0.82 + cytoN * 0.45)

                    if nd < nucleusPx * depthScale {
                        // Inside nucleus — bright with a soft falloff to the
                        // cytoplasm at its edge.
                        let nt = max(0, 1 - nd / (nucleusPx * depthScale))
                        let nGlow = pow(nt, 0.7)
                        col = cytoLit + (nucleusCol - cytoLit) * nGlow
                        alpha = 0.92
                    } else if vd < vacRadiusPx * depthScale {
                        // Vacuole — dark soft circle (less prominent than
                        // nucleus). Reads as a second organelle.
                        let vt = max(0, 1 - vd / (vacRadiusPx * depthScale))
                        let vMix = pow(vt, 0.6) * 0.75
                        col = cytoLit + (vacuoleCol - cytoLit) * vMix
                        alpha = 0.88
                    } else if d > radiusMod - membranePx {
                        // Membrane ring — dark with a soft edge.
                        let edgeT = max(0, (d - (radiusMod - membranePx)) / membranePx)
                        let mGlow = 1 - pow(edgeT, 0.6) * 0.4
                        col = membraneCol * mGlow
                        let outerFade = max(0, (d - (radiusMod * 0.92)) / (radiusMod * 0.08))
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
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    private func drawCytoBridge(
        into pixels: inout [UInt8], w: Int, h: Int,
        a: SIMD2<Float>, b: SIMD2<Float>,
        color: SIMD3<Float>, halfWidth: Float
    ) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        if len < 1 { return }
        let nx = -dy / len  // normal
        let ny = dx / len
        let steps = Int(len.rounded(.up))
        for s in 0..<steps {
            let t = Float(s) / Float(max(1, steps - 1))
            let cx = a.x + dx * t
            let cy = a.y + dy * t
            // Bridge tapers at the ends.
            let taper = sin(t * .pi)
            let hw = halfWidth * taper
            let hwI = Int(hw.rounded(.up))
            for off in -hwI...hwI {
                let f = Float(off) / max(0.01, hw)
                let alpha: Float = max(0, (1 - f * f)) * 0.65
                let pxF = cx + nx * Float(off)
                let pyF = cy + ny * Float(off)
                let xi = Int(pxF.rounded()), yi = Int(pyF.rounded())
                if xi < 0 || xi >= w || yi < 0 || yi >= h { continue }
                let idx = 4 * (xi + yi * w)
                let bgR = Float(pixels[idx + 0]) / 255
                let bgG = Float(pixels[idx + 1]) / 255
                let bgB = Float(pixels[idx + 2]) / 255
                pixels[idx + 0] = toByte(bgR * (1 - alpha) + color.x * alpha)
                pixels[idx + 1] = toByte(bgG * (1 - alpha) + color.y * alpha)
                pixels[idx + 2] = toByte(bgB * (1 - alpha) + color.z * alpha)
            }
        }
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
