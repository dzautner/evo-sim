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
    public var sphereRadius: Float = 1.4
    /// Smooth-min sharpness; smaller = softer cell merging. Lowered so
    /// touching cells blend into one membrane instead of staying spherical.
    public var smoothK: Float = 0.28
    /// fBm amplitude added to the SDF itself so membranes are irregular
    /// (lumpy, like real cells) rather than perfectly spherical.
    public var membraneNoise: Float = 0.18
    /// Spatial scale of the membrane-noise lumps in world units.
    public var membraneNoiseScale: Float = 1.1
    /// Max ray steps per pixel before giving up (background).
    public var maxSteps: Int = 64
    /// Minimum SDF value treated as "hit".
    public var hitEpsilon: Float = 0.04
    /// Internal supersample factor. SS=1 preserves grain. SS=2 smooths
    /// edges but also smooths the grain — usually want SS=1 for the
    /// microscope look.
    public var supersample: Int = 1
    /// Samples per pixel within each supersample (extra noise vs AA tradeoff).
    public var samplesPerPixel: Int = 1
    /// Membrane grain amount — applied via fBm noise (spatially correlated),
    /// not per-pixel white noise. Looks like real photographic grain.
    public var grainStrength: Float = 0.45
    /// Grain feature scale in world units (smaller = finer grain).
    public var grainScale: Float = 0.55
    /// Photon-shot noise factor (brighter regions have proportionally more
    /// noise, like a real microscope sensor).
    public var photonNoise: Float = 0.18

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
        // Render at SS resolution then 2D-average down. Grain ends up at
        // sub-pixel scale ⇒ looks like photographic grain, not pixels.
        let ss = max(1, supersample)
        let hiW = width * ss
        let hiH = height * ss
        let hires = renderAtResolution(world, w: hiW, h: hiH)
        if ss == 1 { return hires }
        // Box-filter downsample.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ss2 = ss * ss
        for py in 0..<height {
            for px in 0..<width {
                var r: Int = 0, g: Int = 0, b: Int = 0
                for dy in 0..<ss {
                    for dx in 0..<ss {
                        let sx = px * ss + dx
                        let sy = py * ss + dy
                        let n = 4 * (sx + sy * hiW)
                        r += Int(hires[n + 0])
                        g += Int(hires[n + 1])
                        b += Int(hires[n + 2])
                    }
                }
                let n = 4 * (px + py * width)
                pixels[n + 0] = UInt8(r / ss2)
                pixels[n + 1] = UInt8(g / ss2)
                pixels[n + 2] = UInt8(b / ss2)
                pixels[n + 3] = 255
            }
        }
        return pixels
    }

    private func renderAtResolution(_ world: World, w: Int, h: Int) -> [UInt8] {
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

        // Bilinear value-noise: smooth-interpolated random per integer grid
        // cell. Result is spatially correlated, unlike per-pixel white noise.
        @inline(__always)
        func valueNoise(_ x: Float, _ y: Float, _ z: Float, _ seed: UInt32) -> Float {
            let xi = Int(x.rounded(.down))
            let yi = Int(y.rounded(.down))
            let zi = Int(z.rounded(.down))
            let fx = x - Float(xi)
            let fy = y - Float(yi)
            let fz = z - Float(zi)
            @inline(__always)
            func corner(_ ix: Int, _ iy: Int, _ iz: Int) -> Float {
                let a = UInt32(truncatingIfNeeded: ix &* 374761393)
                let b = UInt32(truncatingIfNeeded: iy &* 668265263)
                let c = UInt32(truncatingIfNeeded: iz &* 1274126177) &+ seed
                return hash01(a, b, c)
            }
            let sx = fx * fx * (3 - 2 * fx)
            let sy = fy * fy * (3 - 2 * fy)
            let sz = fz * fz * (3 - 2 * fz)
            let c000 = corner(xi, yi, zi)
            let c100 = corner(xi + 1, yi, zi)
            let c010 = corner(xi, yi + 1, zi)
            let c110 = corner(xi + 1, yi + 1, zi)
            let c001 = corner(xi, yi, zi + 1)
            let c101 = corner(xi + 1, yi, zi + 1)
            let c011 = corner(xi, yi + 1, zi + 1)
            let c111 = corner(xi + 1, yi + 1, zi + 1)
            let x00 = c000 + (c100 - c000) * sx
            let x10 = c010 + (c110 - c010) * sx
            let x01 = c001 + (c101 - c001) * sx
            let x11 = c011 + (c111 - c011) * sx
            let y0 = x00 + (x10 - x00) * sy
            let y1 = x01 + (x11 - x01) * sy
            return y0 + (y1 - y0) * sz
        }

        @inline(__always)
        func fbm(_ x: Float, _ y: Float, _ z: Float, _ seed: UInt32, octaves: Int = 4) -> Float {
            var total: Float = 0
            var amp: Float = 1
            var freq: Float = 1
            var maxAmp: Float = 0
            for o in 0..<octaves {
                total += (valueNoise(x * freq, y * freq, z * freq, seed &+ UInt32(o)) - 0.5) * amp
                maxAmp += amp
                amp *= 0.5
                freq *= 2.07
            }
            return total / maxAmp
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

        let memNoiseAmp = membraneNoise
        let memNoiseScale = membraneNoiseScale

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
            // Irregular membrane: only modulate the SDF when we're already
            // close to a surface — far away, fBm would create phantom blobs
            // in empty space (and rectangular bin artifacts).
            if memNoiseAmp > 0 && abs(d) < 3.0 {
                let mp = p / memNoiseScale
                let lump = fbm(mp.x, mp.y, mp.z, 0x91, octaves: 3) * memNoiseAmp
                // Falloff so the noise smoothly vanishes away from the
                // surface (avoids a sudden change at the cutoff distance).
                let proximity = max(0, 1 - abs(d) / 3.0)
                d -= lump * proximity
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

                for _ in 0..<samplesPerPixel {
                    // Supersample handles AA — no jitter needed; grain comes
                    // from world-space fBm at the membrane.
                    let u = (Float(px) + 0.5) * invW
                    let v = (Float(py) + 0.5) * invH
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
                            let lambert: Float = max(0, simd_dot(n, -lightDir))
                            let shadow: Float = softShadow(from: rayPos)
                            let halfDir = simd_normalize(-lightDir + SIMD3<Float>(0, 0, -1))
                            let specBase: Float = max(0, simd_dot(n, halfDir))
                            let spec: Float = powf(specBase, 14.0) * 0.55
                            let fresnelBase: Float = 1 - max(0, -n.z)
                            let fresnel: Float = powf(fresnelBase, 3.0)
                            let diffuseLight: Float = (0.4 + 0.55 * lambert) * shadow
                            let memDiffuse: SIMD3<Float> = memCol * diffuseLight
                            var lit: SIMD3<Float> = darkCol + memDiffuse
                            let specBoost: SIMD3<Float> = specCol * (spec * shadow)
                            lit = lit + specBoost
                            let fresnelTerm: Float = 1 - 0.25 * fresnel
                            let fresnelGlow: SIMD3<Float> = memCol * (0.15 * fresnel)
                            lit = lit * fresnelTerm + fresnelGlow
                            // Membrane grain: 4-octave fBm sampled in 3D
                            // *world* coordinates so grain sticks to the
                            // creature's surface, not the screen — pans
                            // with body motion like real micrograph noise.
                            let gWorld = rayPos / grainScale
                            let gMem = fbm(gWorld.x, gWorld.y, gWorld.z, 0x4C, octaves: 4)
                            lit *= (1.0 + gMem * grainStrength)
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
                // Photon-shot noise: variance proportional to sqrt(brightness)
                // like a real microscope sensor — brighter regions noisier.
                let lum = (acc.x + acc.y + acc.z) * 0.333
                let shot = (hash01(UInt32(px), UInt32(py), 0x99) - 0.5)
                    * photonNoise * sqrt(max(0.001, lum))
                acc *= (1 + shot)
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
