import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import EvoSimCore

/// Per-pixel 3D raymarcher over a smooth-min SDF of cell metaballs. Designed
/// to produce a biological / electron-microscope aesthetic *from* the
/// rendering process, not from theming applied on top:
///
///   - Cells are spheres in 3D. SDF = smooth-min over all cells in a
///     spatial bin around the ray. Smooth-min produces real membrane
///     thickness where bodies merge.
///   - Per-pixel ray jitter (stochastic AA + sub-sample within the cell
///     SDF) introduces real grain — the "noise" of an undersampled
///     raymarcher. Looks like microscope grain because it IS grain.
///   - Monochromatic duotone palette: deep teal void → cream membrane.
///     One spec highlight. No saturated colors. Different organisms look
///     similar by default — body plan is what distinguishes them.
///   - Depth attenuation: light scatters through the tank's medium, so
///     deeper bodies fade into the void. Front bodies cast shadow on
///     back bodies (one shadow ray per surface hit).
///
/// Trade-offs: slower than SnapshotRenderer (≈ width × height × ~30 ray
/// steps × cells_per_bin). At 480² with 1k cells, expect 5–15s per frame
/// in release. Acceptable for stills and short GIFs; not for the live app.
public struct RaymarchRenderer {

    public var width: Int
    public var height: Int

    /// Cell radius in world units for the SDF. Larger ⇒ blobbier membrane.
    public var sphereRadius: Float = 1.1
    /// Smooth-min sharpness; smaller = softer cell merging.
    public var smoothK: Float = 0.5
    /// Max ray steps per pixel before giving up (background).
    public var maxSteps: Int = 64
    /// Minimum SDF value treated as "hit".
    public var hitEpsilon: Float = 0.04
    /// Samples per pixel (AA + noise). 1 = fastest + grainiest; 4 = soft.
    public var samplesPerPixel: Int = 1
    /// Random jitter for sampling (controls the grain amount).
    public var jitterMagnitude: Float = 1.5
    /// Film grain — multiplicative noise applied on final color.
    public var filmGrain: Float = 0.18

    /// Camera setup — orthographic looking down +Z. Tank XY maps to image XY.
    public var orthographic: Bool = true

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
        let cells = world.colony.cells
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        // Build a flat array of cell positions + cell index for the SDF.
        let n = cells.count
        var pos = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n { pos[i] = cells[i].position }

        // World bounds for the camera frustum.
        let bx = world.bounds.x, by = world.bounds.y, bz = world.bounds.z

        // Spatial bins so a ray sample only consults nearby cells. Bin
        // resolution sized to cover ~2× the sphere radius per bin.
        let binSize: Float = max(2.0, sphereRadius * 2.5)
        let bw = max(1, Int((bx / binSize).rounded(.up)))
        let bh = max(1, Int((by / binSize).rounded(.up)))
        let bd = max(1, Int((bz / binSize).rounded(.up)))
        var bins = [[Int32]](repeating: [], count: bw * bh * bd)
        for i in 0..<n {
            let p = pos[i]
            let ix = max(0, min(bw - 1, Int(p.x / binSize)))
            let iy = max(0, min(bh - 1, Int(p.y / binSize)))
            let iz = max(0, min(bd - 1, Int(p.z / binSize)))
            bins[ix + bw * (iy + bh * iz)].append(Int32(i))
        }

        // Light: a single soft directional + small ambient, plus a key
        // top-back spec. Colors chosen for the duotone EM look.
        let lightDir = simd_normalize(SIMD3<Float>(0.35, 0.45, -0.75))
        let voidCol  = SIMD3<Float>(0.04, 0.06, 0.08)        // deep teal
        let darkCol  = SIMD3<Float>(0.16, 0.13, 0.10)        // mid sepia
        let memCol   = SIMD3<Float>(0.92, 0.84, 0.66)        // membrane cream
        let specCol  = SIMD3<Float>(1.00, 0.96, 0.86)
        let inscatterCol = SIMD3<Float>(0.10, 0.13, 0.14)    // back-scatter haze

        let invW = 1.0 / Float(w)
        let invH = 1.0 / Float(h)
        let camDepthFalloff: Float = 0.018  // attenuation per world unit of depth

        // PCG-based hash for deterministic per-pixel jitter.
        @inline(__always)
        func hash01(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> Float {
            var x = a &+ 0x9E3779B9
            x ^= b &+ 0x85EBCA6B
            x = (x ^ (x >> 16)) &* 0x21F0AAAD
            x = (x ^ (x >> 15)) &* 0x735A2D97
            x ^= c &+ 0xC2B2AE35
            x = (x ^ (x >> 15))
            return Float(x & 0xFFFFFF) / Float(0x1000000)
        }

        let radius = sphereRadius
        let k = smoothK

        // Search range chosen so every cell within the smooth-min's
        // significant influence is sampled — eliminates the cubic
        // "voxel" artifacts caused by an undersized search radius.
        // Smooth-min with k=0.5 has ~exp(-0.5*d) influence; we want to
        // catch contributions down to ~1% which is at d ≈ 9 units.
        let influenceWorld: Float = max(sphereRadius * 3, 9.0)
        let searchBins: Int = max(3, Int((influenceWorld / binSize).rounded(.up)))

        @inline(__always)
        func sdfAt(_ p: SIMD3<Float>) -> Float {
            let ix = max(0, min(bw - 1, Int(p.x / binSize)))
            let iy = max(0, min(bh - 1, Int(p.y / binSize)))
            let iz = max(0, min(bd - 1, Int(p.z / binSize)))
            let x0 = max(0, ix - searchBins), x1 = min(bw - 1, ix + searchBins)
            let y0 = max(0, iy - searchBins), y1 = min(bh - 1, iy + searchBins)
            let z0 = max(0, iz - searchBins), z1 = min(bd - 1, iz + searchBins)
            var d: Float = 1e6
            for bz in z0...z1 {
                for by in y0...y1 {
                    for bx in x0...x1 {
                        for ci in bins[bx + bw * (by + bh * bz)] {
                            let dp = p - pos[Int(ci)]
                            let dist = simd_length(dp) - radius
                            // exponential smooth min
                            let h = expf(-k * d) + expf(-k * dist)
                            d = -logf(max(h, 1e-12)) / k
                        }
                    }
                }
            }
            return d
        }

        @inline(__always)
        func sdfNormal(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let e: Float = 0.06
            let dx = sdfAt(p + SIMD3<Float>(e, 0, 0)) - sdfAt(p - SIMD3<Float>(e, 0, 0))
            let dy = sdfAt(p + SIMD3<Float>(0, e, 0)) - sdfAt(p - SIMD3<Float>(0, e, 0))
            let dz = sdfAt(p + SIMD3<Float>(0, 0, e)) - sdfAt(p - SIMD3<Float>(0, 0, e))
            let g = SIMD3<Float>(dx, dy, dz)
            let l = simd_length(g)
            return l > 1e-6 ? g / l : SIMD3<Float>(0, 0, -1)
        }

        // Soft shadow toward the key light: short march toward `lightDir`
        // looking for occluders. One ray per surface hit — cheap.
        @inline(__always)
        func softShadow(from origin: SIMD3<Float>) -> Float {
            let toLight = -lightDir
            var t: Float = 0.4
            var occ: Float = 1.0
            for _ in 0..<8 {
                let q = origin + toLight * t
                let d = sdfAt(q)
                if d < 0.01 { return 0.25 }
                occ = min(occ, 6.0 * d / t)
                t += max(0.4, d)
                if t > 8.0 { break }
            }
            return max(0.3, occ)
        }

        for py in 0..<h {
            for px in 0..<w {
                var acc = SIMD3<Float>(0, 0, 0)

                for s in 0..<samplesPerPixel {
                    // Jittered subpixel sample. The jitter is the "noise".
                    let jx = (hash01(UInt32(px), UInt32(py), UInt32(s * 2)) - 0.5) * jitterMagnitude
                    let jy = (hash01(UInt32(px), UInt32(py), UInt32(s * 2 + 1)) - 0.5) * jitterMagnitude

                    let u = (Float(px) + 0.5 + jx) * invW
                    let v = (Float(py) + 0.5 + jy) * invH
                    // Camera: ortho, looking down +Z. Map UV to world xy.
                    let wx = u * bx
                    let wy = v * by
                    let rayDir = SIMD3<Float>(0, 0, 1)
                    var rayPos = SIMD3<Float>(wx, wy, 0)

                    var color = voidCol
                    var hit = false
                    var depthTraveled: Float = 0
                    for _ in 0..<maxSteps {
                        let d = sdfAt(rayPos)
                        if d < hitEpsilon {
                            // Hit. Shade.
                            let n = sdfNormal(rayPos)
                            let lambert = max(0, simd_dot(n, -lightDir))
                            let shadow = softShadow(from: rayPos)
                            let halfDir = simd_normalize(-lightDir + SIMD3<Float>(0, 0, -1))
                            let spec = pow(max(0, simd_dot(n, halfDir)), 14.0) * 0.55
                            // Subsurface: backlight bleed inversely with normal·view.
                            let fresnel = pow(1 - max(0, -n.z), 3.0)
                            var lit = darkCol + memCol * (0.4 + 0.55 * lambert) * shadow
                            lit += specCol * spec * shadow
                            lit = lit * (1 - 0.25 * fresnel) + memCol * 0.15 * fresnel
                            // Depth attenuation: cells deeper into the tank
                            // fade toward the inscatter color, simulating
                            // medium absorption.
                            let depth01 = rayPos.z / bz
                            let atten = expf(-depthTraveled * camDepthFalloff)
                            color = mix(inscatterCol, lit, t: atten) * (1.0 - 0.4 * depth01)
                            hit = true
                            break
                        }
                        rayPos.z += max(d * 0.85, 0.12)
                        depthTraveled += max(d * 0.85, 0.12)
                        if rayPos.z > bz { break }
                    }

                    if !hit {
                        // Faint inscatter background — not pure void; gives
                        // the "looking into water" feel.
                        let depth01 = simd_length(SIMD2<Float>(u - 0.5, v - 0.5))
                        color = mix(voidCol, inscatterCol, t: 1 - depth01 * 0.8)
                    }
                    acc += color
                }

                acc *= (1.0 / Float(samplesPerPixel))
                // Film grain — luminance-modulating noise so the membrane
                // texture reads as biological grain, not flat plastic.
                let grain = (hash01(UInt32(px), UInt32(py), 0x77) - 0.5) * filmGrain
                acc *= (1 + grain)
                let n = 4 * (px + py * w)
                pixels[n + 0] = toByte(acc.x)
                pixels[n + 1] = toByte(acc.y)
                pixels[n + 2] = toByte(acc.z)
                pixels[n + 3] = 255
            }
        }

        return pixels
    }

    @inline(__always)
    private func toByte(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, v * 255)))
    }

    @inline(__always)
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
