import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import EvoSimCore

/// Mutable camera state shared across frame renders so a GIF / live app
/// can smoothly interpolate viewport changes (no jumpy zoom).
public final class MicroscopeCamera {
    public var minX: Float = 0
    public var minY: Float = 0
    public var extent: Float = 0
    public var initialized: Bool = false
    /// Smoothing factor per render call. 0 = no smoothing (snap to target);
    /// 1 = never move. 0.85 ≈ takes ~6 frames to converge.
    public var smoothing: Float = 0.85
    public init() {}
}

/// Renders the world to look like a transmission electron micrograph: pale
/// warm-grey background with film grain + dust, organisms as DARK
/// electron-dense bodies with a single thin membrane outline and internal
/// organelles (nuclei, vacuoles) visible through translucent cytoplasm.
///
/// Crucially: each organism is rendered as ONE body, not a stack of
/// individual cells. The body shape is a metaball isosurface over that
/// organism's cells, so a 30-cell organism reads as a single creature with
/// 30 internal structures, not as 30 dots that happen to be near each other.
public struct MicroscopyRenderer {
    public var width: Int
    public var height: Int
    /// Optional persistent camera.
    public var camera: MicroscopeCamera? = nil
    /// Per-cell radius in world units used by the metaball envelope.
    public var cellRadius: Float = 1.6
    /// Frame the largest organism instead of the whole tank.
    public var followLargestOrganism: Bool = false
    public var followPadding: Float = 8.0
    public var minFrameExtent: Float = 18.0

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

        // ---------------- Camera viewport ----------------
        var viewMinX: Float = 0, viewMinY: Float = 0
        var viewExtentX: Float = bx, viewExtentY: Float = by
        if followLargestOrganism, !world.colony.cells.isEmpty {
            var counts: [UInt32: Int] = [:]
            for c in world.colony.cells { counts[c.organismId, default: 0] += 1 }
            if let (bestOid, _) = counts.max(by: { $0.value < $1.value }) {
                var minP = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
                var maxP = SIMD2<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
                for c in world.colony.cells where c.organismId == bestOid {
                    minP.x = min(minP.x, c.position.x); minP.y = min(minP.y, c.position.y)
                    maxP.x = max(maxP.x, c.position.x); maxP.y = max(maxP.y, c.position.y)
                }
                let side = max(minFrameExtent, max((maxP.x - minP.x), (maxP.y - minP.y)) + followPadding * 2)
                let cx = (minP.x + maxP.x) * 0.5, cy = (minP.y + maxP.y) * 0.5
                var tMinX = cx - side * 0.5, tMinY = cy - side * 0.5, tExt = side
                if let cam = camera {
                    if !cam.initialized {
                        cam.minX = tMinX; cam.minY = tMinY; cam.extent = tExt; cam.initialized = true
                    } else {
                        let s = max(0, min(0.99, cam.smoothing))
                        cam.minX = cam.minX * s + tMinX * (1 - s)
                        cam.minY = cam.minY * s + tMinY * (1 - s)
                        cam.extent = cam.extent * s + tExt * (1 - s)
                    }
                    tMinX = cam.minX; tMinY = cam.minY; tExt = cam.extent
                }
                viewMinX = tMinX; viewMinY = tMinY
                viewExtentX = tExt; viewExtentY = tExt
            }
        }
        let pxPerUnitX = Float(w) / viewExtentX
        let pxPerUnitY = Float(h) / viewExtentY
        @inline(__always) func wx2px(_ wx: Float) -> Float { (wx - viewMinX) * pxPerUnitX }
        @inline(__always) func wy2py(_ wy: Float) -> Float { (wy - viewMinY) * pxPerUnitY }

        // ---------------- TEM background ----------------
        // Pale warm-ivory, with heavy fBm "film" grain and a slight
        // sepia tint variation across the frame. Also samples the
        // nutrient + morphogen fields so food pellets show as faint
        // amber blotches and morphogen signaling as faint cool tint.
        let bgPale = SIMD3<Float>(0.84, 0.81, 0.76)
        let bgShadow = SIMD3<Float>(0.70, 0.66, 0.60)
        let foodTint = SIMD3<Float>(0.80, 0.62, 0.32)
        let morphoTint = SIMD3<Float>(0.45, 0.55, 0.68)
        for py in 0..<h {
            for px in 0..<w {
                let u = Float(px) / Float(w)
                let v = Float(py) / Float(h)
                // Big-scale uneven density (film exposure variation).
                let n1 = Self.valueNoise(u * 3.1, v * 3.1, 0x10)
                let n2 = Self.valueNoise(u * 11.0, v * 11.0, 0x21) * 0.55
                let nMix = max(0, min(1, 0.35 + (n1 + n2 - 0.7) * 1.1))
                var bg = mix(bgPale, bgShadow, t: nMix)
                // Sample chemistry + morphogen at the world position this
                // pixel corresponds to (respects viewport).
                let wx = viewMinX + u * viewExtentX
                let wy = viewMinY + v * viewExtentY
                // Sum chemistry along z=middle slice for performance.
                if let g = world.chemistry.gridIndex(for: SIMD3<Float>(wx, wy, world.bounds.z * 0.5)) {
                    let nut = world.chemistry.sample(at: g.i, g.j, g.k)
                    let nutT = min(0.45, nut * 0.025)
                    bg = mix(bg, foodTint, t: nutT)
                    let mor = world.morphogen.sample(at: g.i, g.j, g.k)
                    let morT = min(0.35, mor * 0.04)
                    bg = mix(bg, morphoTint, t: morT)
                }
                let idx = 4 * (px + py * w)
                pixels[idx + 0] = toByte(bg.x)
                pixels[idx + 1] = toByte(bg.y)
                pixels[idx + 2] = toByte(bg.z)
                pixels[idx + 3] = 255
            }
        }

        // Scatter dust / debris specks across the medium — small dark
        // splotches at random positions, like real micrograph artifacts.
        let dustCount = max(40, (w * h) / 1600)
        for k in 0..<dustCount {
            let rx = Self.hash01(UInt32(k), 0x91, 0)
            let ry = Self.hash01(UInt32(k), 0x92, 0)
            let rs = Self.hash01(UInt32(k), 0x93, 0)
            let dx = Int(rx * Float(w))
            let dy = Int(ry * Float(h))
            let radius = max(1, Int(rs * 2.2))
            let darkness: Float = 0.45 + rs * 0.4
            for oy in -radius...radius {
                for ox in -radius...radius {
                    let d2 = ox * ox + oy * oy
                    if d2 > radius * radius { continue }
                    let xi = dx + ox, yi = dy + oy
                    if xi < 0 || xi >= w || yi < 0 || yi >= h { continue }
                    let idx = 4 * (xi + yi * w)
                    let fade: Float = 1 - Float(d2) / Float(radius * radius)
                    let factor: Float = 1 - darkness * fade
                    pixels[idx + 0] = toByte(Float(pixels[idx + 0]) / 255 * factor)
                    pixels[idx + 1] = toByte(Float(pixels[idx + 1]) / 255 * factor)
                    pixels[idx + 2] = toByte(Float(pixels[idx + 2]) / 255 * factor)
                }
            }
        }

        // ---------------- Group cells by organism ----------------
        var cellsByOrg: [UInt32: [Int]] = [:]
        for (i, c) in world.colony.cells.enumerated() {
            cellsByOrg[c.organismId, default: []].append(i)
        }

        // Z-sort organisms back-to-front by mean Z.
        struct OrgRender {
            var oid: UInt32
            var cellIdx: [Int]
            var meanZ: Float
        }
        var orgs: [OrgRender] = []
        for (oid, indices) in cellsByOrg {
            var sz: Float = 0
            for i in indices { sz += world.colony.cells[i].position.z }
            orgs.append(OrgRender(oid: oid, cellIdx: indices, meanZ: sz / Float(indices.count)))
        }
        orgs.sort { $0.meanZ < $1.meanZ }

        // ---------------- Per-organism body render ----------------
        // For each organism, accumulate a metaball field over its cells,
        // threshold it for the outer membrane, fill the interior with
        // semi-transparent dark cytoplasm. Then draw each cell's nucleus
        // as a small darker spot, and vacuoles as paler spots.
        let rWorld = cellRadius
        let r2World = rWorld * rWorld
        // Influence radius in pixels (for bounding box).
        let influencePxX = (rWorld * 1.6) * pxPerUnitX
        let influencePxY = (rWorld * 1.6) * pxPerUnitY

        for org in orgs {
            // Gather projected cell positions for this org with their
            // per-cell predation signal (so the renderer can show local
            // "mouth" regions wherever predation is active).
            struct ProjCell {
                var px: Float; var py: Float; var z: Float
                var energy: Float
                var predation: Float
            }
            var projected: [ProjCell] = []
            projected.reserveCapacity(org.cellIdx.count)
            var bbMinX = Float.greatestFiniteMagnitude, bbMinY = Float.greatestFiniteMagnitude
            var bbMaxX = -Float.greatestFiniteMagnitude, bbMaxY = -Float.greatestFiniteMagnitude
            for i in org.cellIdx {
                let c = world.colony.cells[i]
                let pX = wx2px(c.position.x)
                let pY = wy2py(c.position.y)
                let pred = world.colony.predation.indices.contains(i)
                    ? max(0, world.colony.predation[i]) : 0
                projected.append(ProjCell(
                    px: pX, py: pY, z: c.position.z,
                    energy: c.energy,
                    predation: pred
                ))
                bbMinX = min(bbMinX, pX - influencePxX)
                bbMinY = min(bbMinY, pY - influencePxY)
                bbMaxX = max(bbMaxX, pX + influencePxX)
                bbMaxY = max(bbMaxY, pY + influencePxY)
            }
            // Mean role signals for this organism — drives tonal hint
            // (warmer = predator, cooler = structural). Subtle, not rainbow.
            var meanPred: Float = 0, meanMotor: Float = 0
            for i in org.cellIdx {
                if world.colony.predation.indices.contains(i) {
                    meanPred += max(0, world.colony.predation[i])
                }
                if world.colony.contraction.indices.contains(i) {
                    meanMotor += max(0, world.colony.contraction[i])
                }
            }
            meanPred /= Float(org.cellIdx.count)
            meanMotor /= Float(org.cellIdx.count)

            // Body fill colour: dark with a subtle role tint.
            let bodyBase = SIMD3<Float>(0.20, 0.19, 0.18)
            let bodyPred = SIMD3<Float>(0.26, 0.18, 0.16)  // warm-dark
            let bodyMot  = SIMD3<Float>(0.21, 0.21, 0.18)
            var bodyCol = mix(bodyBase, bodyPred, t: min(1, meanPred * 2.0))
            bodyCol = mix(bodyCol, bodyMot, t: min(1, meanMotor * 1.2))
            // Slight depth fade (front organisms darker = closer to lens).
            let zNorm = max(0, min(1, projected.reduce(0) { $0 + $1.z } / Float(projected.count) / bz))
            let depthFactor: Float = 0.85 + 0.15 * zNorm
            bodyCol *= depthFactor

            // Bounding box in pixels (clamped).
            let x0 = max(0, Int(bbMinX) - 1), x1 = min(w - 1, Int(bbMaxX) + 1)
            let y0 = max(0, Int(bbMinY) - 1), y1 = min(h - 1, Int(bbMaxY) + 1)
            if x0 > x1 || y0 > y1 { continue }

            // Influence radius in pixels for the field falloff.
            let influence = rWorld * pxPerUnitX  // body cells size — use X scale
            let influence2 = influence * influence
            let surfaceThreshold: Float = 0.6  // isovalue cutoff

            for py in y0...y1 {
                for px in x0...x1 {
                    let qx = Float(px), qy = Float(py)
                    var field: Float = 0
                    // Per-pixel predation intensity from nearby cells —
                    // weighted by inverse distance so the hotspot is
                    // localized to the active predator cell.
                    var predField: Float = 0
                    var predWeight: Float = 0
                    for c in projected {
                        let dx = c.px - qx
                        let dy = c.py - qy
                        let d2 = dx * dx + dy * dy
                        if d2 > influence2 * 4 { continue }  // cull
                        let v: Float = max(0, 1 - d2 / (influence2 * 1.2))
                        field += v * v
                        if c.predation > 0.05 {
                            let w = v * v
                            predField += c.predation * w
                            predWeight += w
                        }
                    }
                    if field < surfaceThreshold * 0.35 { continue }
                    let predLocal: Float = predWeight > 0
                        ? min(1, predField / predWeight) : 0

                    let idx = 4 * (px + py * w)
                    let bgR = Float(pixels[idx + 0]) / 255
                    let bgG = Float(pixels[idx + 1]) / 255
                    let bgB = Float(pixels[idx + 2]) / 255

                    if field > surfaceThreshold {
                        // INTERIOR — semi-transparent dark cytoplasm with
                        // cytoplasm-noise texture in world coords.
                        let wx = (viewMinX + qx / pxPerUnitX)
                        let wy = (viewMinY + qy / pxPerUnitY)
                        let texN = Self.fbm(wx * 1.6, wy * 1.6, 0x33, octaves: 3)
                        var interior = bodyCol * (0.88 + texN * 0.25)
                        // MOUTH GLOW: cells actively predating tint this
                        // region red-warm. Localized — a mouth on one end
                        // of the body is visually distinct from the rest.
                        if predLocal > 0.05 {
                            let mouthCol = SIMD3<Float>(0.55, 0.08, 0.06)
                            let t = min(1, predLocal * 1.8)
                            interior = mix(interior, mouthCol, t: t)
                        }
                        let alphaInner: Float = 0.78
                        pixels[idx + 0] = toByte(bgR * (1 - alphaInner) + interior.x * alphaInner)
                        pixels[idx + 1] = toByte(bgG * (1 - alphaInner) + interior.y * alphaInner)
                        pixels[idx + 2] = toByte(bgB * (1 - alphaInner) + interior.z * alphaInner)
                    } else {
                        // MEMBRANE band — the dark thin edge where field
                        // crosses the isovalue. Strongest at the surface.
                        let t = (field - surfaceThreshold * 0.35) / (surfaceThreshold * 0.65)
                        let edge: Float = sin(t * .pi)  // 0 at outer/inner, 1 at middle
                        let memCol = SIMD3<Float>(0.08, 0.07, 0.06) * depthFactor
                        let alphaEdge: Float = edge * 0.88
                        pixels[idx + 0] = toByte(bgR * (1 - alphaEdge) + memCol.x * alphaEdge)
                        pixels[idx + 1] = toByte(bgG * (1 - alphaEdge) + memCol.y * alphaEdge)
                        pixels[idx + 2] = toByte(bgB * (1 - alphaEdge) + memCol.z * alphaEdge)
                    }
                }
            }

            // ----- Internal structures: nuclei (dark spots) + vacuoles
            // (pale spots) per cell, INSIDE the body envelope. These read
            // as organelles within one organism, not separate dots.
            for c in projected {
                let nucleusPx = max(1.2, influence * 0.18)
                let vacRadiusPx = max(0.8, influence * 0.11)
                // Nucleus offset deterministic per cell (use position hash).
                let seedX = UInt32(truncatingIfNeeded: Int(c.px * 7 + c.py * 13))
                let nOffX = (Self.hash01(seedX, 1, 0) - 0.5) * influence * 0.3
                let nOffY = (Self.hash01(seedX, 2, 0) - 0.5) * influence * 0.3
                let nCx = c.px + nOffX, nCy = c.py + nOffY
                let vAng = Self.hash01(seedX, 3, 0) * 6.2831
                let vCx = c.px + cos(vAng) * influence * 0.32
                let vCy = c.py + sin(vAng) * influence * 0.32

                // Nucleus: small dark spot.
                let nPad = Int(nucleusPx.rounded(.up)) + 1
                for oy in -nPad...nPad {
                    for ox in -nPad...nPad {
                        let xi = Int(nCx) + ox, yi = Int(nCy) + oy
                        if xi < 0 || xi >= w || yi < 0 || yi >= h { continue }
                        let dx = Float(ox), dy = Float(oy)
                        let d2 = dx * dx + dy * dy
                        let r2px = nucleusPx * nucleusPx
                        if d2 > r2px { continue }
                        let fade: Float = max(0, 1 - sqrt(d2) / nucleusPx)
                        let alpha: Float = pow(fade, 0.7) * 0.85
                        let idx = 4 * (xi + yi * w)
                        pixels[idx + 0] = toByte(Float(pixels[idx + 0]) / 255 * (1 - alpha) + 0.03 * alpha)
                        pixels[idx + 1] = toByte(Float(pixels[idx + 1]) / 255 * (1 - alpha) + 0.03 * alpha)
                        pixels[idx + 2] = toByte(Float(pixels[idx + 2]) / 255 * (1 - alpha) + 0.03 * alpha)
                    }
                }
                // Vacuole: small pale spot.
                let vPad = Int(vacRadiusPx.rounded(.up)) + 1
                for oy in -vPad...vPad {
                    for ox in -vPad...vPad {
                        let xi = Int(vCx) + ox, yi = Int(vCy) + oy
                        if xi < 0 || xi >= w || yi < 0 || yi >= h { continue }
                        let dx = Float(ox), dy = Float(oy)
                        let d2 = dx * dx + dy * dy
                        let r2px = vacRadiusPx * vacRadiusPx
                        if d2 > r2px { continue }
                        let fade: Float = max(0, 1 - sqrt(d2) / vacRadiusPx)
                        let alpha: Float = pow(fade, 0.8) * 0.5
                        let idx = 4 * (xi + yi * w)
                        let pale: SIMD3<Float> = SIMD3<Float>(0.75, 0.72, 0.66)
                        pixels[idx + 0] = toByte(Float(pixels[idx + 0]) / 255 * (1 - alpha) + pale.x * alpha)
                        pixels[idx + 1] = toByte(Float(pixels[idx + 1]) / 255 * (1 - alpha) + pale.y * alpha)
                        pixels[idx + 2] = toByte(Float(pixels[idx + 2]) / 255 * (1 - alpha) + pale.z * alpha)
                    }
                }
            }
            _ = r2World
        }

        // ---------------- Predation events ----------------
        // Dark angular streaks where a predator drained a prey this tick.
        // Reads as a small "bite" mark with the wound darkening at the
        // predator's mouth-end.
        for ev in world.colony.recentPredations {
            let ageT = Float(ev.age) / Float(max(1, world.colony.predationEventLifetime))
            let alpha = max(0, 0.7 * (1 - ageT))
            let pax = wx2px(ev.predator.x), pay = wy2py(ev.predator.y)
            let pbx = wx2px(ev.prey.x), pby = wy2py(ev.prey.y)
            drawDarkStreak(into: &pixels, w: w, h: h,
                           x0: pax, y0: pay, x1: pbx, y1: pby, alpha: alpha)
        }

        // ---------------- Global film-grain + slight blur ----------------
        // Heavy luminance grain over the entire image (film not pixels).
        for py in 0..<h {
            for px in 0..<w {
                let g = (Self.hash01(UInt32(px), UInt32(py), 0xC1) - 0.5) * 0.08
                let idx = 4 * (px + py * w)
                pixels[idx + 0] = toByte(Float(pixels[idx + 0]) / 255 + g)
                pixels[idx + 1] = toByte(Float(pixels[idx + 1]) / 255 + g)
                pixels[idx + 2] = toByte(Float(pixels[idx + 2]) / 255 + g)
            }
        }

        // Vignette — pronounced corner darkening (microscope eyepiece).
        let cxf = Float(w) * 0.5, cyf = Float(h) * 0.5
        let maxR = sqrt(cxf * cxf + cyf * cyf)
        for py in 0..<h {
            for px in 0..<w {
                let dx = Float(px) - cxf
                let dy = Float(py) - cyf
                let r01 = sqrt(dx * dx + dy * dy) / maxR
                let vignette: Float = 1 - r01 * r01 * 0.55
                let idx = 4 * (px + py * w)
                pixels[idx + 0] = toByte(Float(pixels[idx + 0]) / 255 * vignette)
                pixels[idx + 1] = toByte(Float(pixels[idx + 1]) / 255 * vignette)
                pixels[idx + 2] = toByte(Float(pixels[idx + 2]) / 255 * vignette)
            }
        }

        // 1-pixel box blur — softens hard edges so nothing looks sharp / CGI.
        var blurred = pixels
        for py in 1..<(h - 1) {
            for px in 1..<(w - 1) {
                var sr: Int = 0, sg: Int = 0, sb: Int = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        let idx = 4 * ((px + ox) + (py + oy) * w)
                        sr += Int(pixels[idx + 0])
                        sg += Int(pixels[idx + 1])
                        sb += Int(pixels[idx + 2])
                    }
                }
                let idx = 4 * (px + py * w)
                blurred[idx + 0] = UInt8(sr / 9)
                blurred[idx + 1] = UInt8(sg / 9)
                blurred[idx + 2] = UInt8(sb / 9)
            }
        }
        return blurred
    }

    // MARK: - Helpers

    @inline(__always)
    private func toByte(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, v * 255)))
    }

    @inline(__always)
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
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

    private func drawDarkStreak(
        into pixels: inout [UInt8], w: Int, h: Int,
        x0: Float, y0: Float, x1: Float, y1: Float, alpha: Float
    ) {
        let dx = x1 - x0, dy = y1 - y0
        let len = sqrt(dx * dx + dy * dy)
        if len < 1 { return }
        let steps = Int(len.rounded(.up))
        for s in 0...steps {
            let t = Float(s) / Float(max(1, steps))
            // Predator end darker, prey end paler.
            let a: Float = alpha * (0.4 + 0.6 * (1 - t))
            let x = x0 + dx * t, y = y0 + dy * t
            let xi = Int(x.rounded()), yi = Int(y.rounded())
            if xi < 0 || xi >= w || yi < 0 || yi >= h { continue }
            let idx = 4 * (xi + yi * w)
            // Darken the pixel toward near-black.
            pixels[idx + 0] = toByte(Float(pixels[idx + 0]) / 255 * (1 - a) + 0.05 * a)
            pixels[idx + 1] = toByte(Float(pixels[idx + 1]) / 255 * (1 - a) + 0.05 * a)
            pixels[idx + 2] = toByte(Float(pixels[idx + 2]) / 255 * (1 - a) + 0.05 * a)
        }
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
