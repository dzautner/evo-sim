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
    public var drawBonds: Bool = true
    public enum ColorMode { case uniform, organism, role }
    /// `.role`: cells colored by their dominant NCA output channel.
    /// `.organism`: hash(organismId) → hue.
    /// `.uniform`: amber/white.
    public var colorMode: ColorMode = .role
    /// When true, cells render as a smooth metaball isosurface — overlapping
    /// cells merge into one blob with a defined silhouette, so an organism
    /// reads as a CREATURE instead of a cell cloud. Slower than splat dots.
    public var metaballMode: Bool = true
    /// Influence radius in world units (not pixels). Larger = blobbier.
    public var metaballRadius: Float = 1.8
    /// Pixel size of one world unit when metaballMode is on; tuned by render
    /// size relative to world bounds.
    public var metaballThreshold: Float = 0.5
    /// Optional motion trail: oldest → newest frames of (cellId, position).
    /// Rendered behind cells as fading dots so locomotion shows in a still.
    public var trailFrames: [[(UInt32, SIMD3<Float>)]] = []

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
        nutrientGain: Float = 0.85,
        cellRadiusPx: Float = 7
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

        // 3-trail. Motion trails (oldest → newest) behind everything.
        if !trailFrames.isEmpty {
            let n = trailFrames.count
            for (k, frame) in trailFrames.enumerated() {
                let age = Float(n - k) / Float(n)        // 1 = oldest, → 0 newest
                let alpha = max(0.04, (1 - age) * 0.45)  // fade older
                let r: Float = 0.95, g: Float = 0.75, b: Float = 0.35
                for (_, pos) in frame {
                    let x = pos.x * pxPerUnit.x
                    let y = pos.y * pxPerUnit.y
                    blendPixel(into: &pixels, w: w, h: h, x: x, y: y,
                               color: SIMD3<Float>(r, g, b), alpha: alpha)
                    // Tiny soft halo to make trails readable at small sizes.
                    let halfA = alpha * 0.4
                    blendPixel(into: &pixels, w: w, h: h, x: x + 1, y: y, color: SIMD3<Float>(r, g, b), alpha: halfA)
                    blendPixel(into: &pixels, w: w, h: h, x: x - 1, y: y, color: SIMD3<Float>(r, g, b), alpha: halfA)
                    blendPixel(into: &pixels, w: w, h: h, x: x, y: y + 1, color: SIMD3<Float>(r, g, b), alpha: halfA)
                    blendPixel(into: &pixels, w: w, h: h, x: x, y: y - 1, color: SIMD3<Float>(r, g, b), alpha: halfA)
                }
            }
        }

        // 3a. Bonds first, behind cells.
        if drawBonds, !world.colony.bonds.isEmpty {
            var idToScreen = [UInt32: SIMD2<Float>]()
            idToScreen.reserveCapacity(world.colony.cells.count)
            for c in world.colony.cells {
                idToScreen[c.id] = SIMD2<Float>(c.position.x * pxPerUnit.x, c.position.y * pxPerUnit.y)
            }
            for bond in world.colony.bonds {
                guard let pa = idToScreen[bond.a], let pb = idToScreen[bond.b] else { continue }
                // Brighter / cooler-toned line for stiffer bond — pops
                // against the amber chemistry background.
                let alpha: Float = min(1, 0.35 + bond.stiffness * 0.18)
                drawLine(into: &pixels, w: w, h: h,
                         x0: pa.x, y0: pa.y, x1: pb.x, y1: pb.y,
                         color: SIMD3<Float>(0.85, 0.95, 1.0), alpha: alpha)
            }
        }

        // Z-sort back to front so cells in front of the tank cleanly overlap
        // those behind them. Z-depth also modulates radius + brightness so
        // the projection acquires a "microscope focus" feel.
        let tankZ = Float(nz) * cf.cellSize

        // Build cell index → (predation, contraction) so we can role-color.
        var roleP = [UInt32: Float]()
        var roleC = [UInt32: Float]()
        roleP.reserveCapacity(world.colony.cells.count)
        roleC.reserveCapacity(world.colony.cells.count)
        for (i, c) in world.colony.cells.enumerated() {
            roleP[c.id] = world.colony.predation.indices.contains(i) ? world.colony.predation[i] : 0
            roleC[c.id] = world.colony.contraction.indices.contains(i) ? world.colony.contraction[i] : 0
        }

        if metaballMode {
            // True metaball pass: per pixel, accumulate Σ rᵢ²/dᵢ² from cells
            // and threshold to produce a smooth blobby silhouette. Color and
            // shading sampled from the dominant nearby cell (with depth +
            // role mixing). Two pixels of soft-edge transition give the
            // "membrane glow" look.
            let worldExtentXY = SIMD2<Float>(Float(nx) * cf.cellSize, Float(ny) * cf.cellSize)
            let worldPerPxX = worldExtentXY.x / Float(w)
            let worldPerPxY = worldExtentXY.y / Float(h)
            let rWorld = metaballRadius
            let r2 = rWorld * rWorld
            // Influence radius in pixels (for the inner-loop bounding box).
            let influencePx = Int((rWorld / worldPerPxX).rounded(.up)) + 1

            // Pre-project all cells to pixel space for fast inner loop.
            struct ProjCell { var px: Float; var py: Float; var z: Float; var color: SIMD3<Float>; var energy: Float }
            var projected: [ProjCell] = []
            projected.reserveCapacity(world.colony.cells.count)
            for cell in world.colony.cells {
                let p = cell.position
                let zNorm = max(0, min(1, p.z / tankZ))
                let depthBright: Float = 0.55 + 0.45 * zNorm
                let energyHeat = 1.0 - expf(-cell.energy * 0.5)
                let col: SIMD3<Float>
                switch colorMode {
                case .role:
                    let pSig = max(0, roleP[cell.id] ?? 0)
                    let mSig = max(0, roleC[cell.id] ?? 0)
                    let predatorCol = SIMD3<Float>(1.0, 0.18, 0.18)
                    let motorCol    = SIMD3<Float>(1.0, 0.55, 0.10)
                    let structCol   = SIMD3<Float>(0.45, 0.95, 0.55)
                    let pw = min(1, pSig * 1.6), mw = min(1, mSig * 1.6)
                    let totalW = pw + mw
                    var base: SIMD3<Float>
                    if totalW < 0.05 {
                        base = structCol
                    } else {
                        let pn = pw / max(0.001, totalW)
                        let mn = mw / max(0.001, totalW)
                        let active = predatorCol * pn + motorCol * mn
                        base = mix(structCol, active, t: min(1, totalW))
                    }
                    col = base * depthBright
                case .organism:
                    let hue = organismHue(cell.organismId)
                    col = hsvToRgb(h: hue, s: 0.85, v: 1.0) * depthBright
                case .uniform:
                    col = SIMD3<Float>(1.0, 0.55, 0.25) * depthBright
                }
                projected.append(ProjCell(
                    px: p.x / worldPerPxX,
                    py: p.y / worldPerPxY,
                    z: p.z, color: col, energy: energyHeat
                ))
            }

            // Spatial bin cells by pixel grid for fast lookup.
            let binsX = max(1, w / max(1, influencePx * 2))
            let binsY = max(1, h / max(1, influencePx * 2))
            let binW = Float(w) / Float(binsX)
            let binH = Float(h) / Float(binsY)
            var bins = [[Int]](repeating: [], count: binsX * binsY)
            for (i, c) in projected.enumerated() {
                let bx = max(0, min(binsX - 1, Int(c.px / binW)))
                let by = max(0, min(binsY - 1, Int(c.py / binH)))
                bins[bx + by * binsX].append(i)
            }
            let binSpan = max(1, Int((Float(influencePx) / min(binW, binH)).rounded(.up)) + 1)

            // Per-pixel field accumulation.
            for py in 0..<h {
                let bypx = py
                let by = max(0, min(binsY - 1, Int(Float(bypx) / binH)))
                let by0 = max(0, by - binSpan), by1 = min(binsY - 1, by + binSpan)
                for px in 0..<w {
                    let bx = max(0, min(binsX - 1, Int(Float(px) / binW)))
                    let bx0 = max(0, bx - binSpan), bx1 = min(binsX - 1, bx + binSpan)

                    var field: Float = 0
                    var bestW: Float = 0
                    var bestColor = SIMD3<Float>(0, 0, 0)
                    var bestEnergy: Float = 0
                    let qx = Float(px), qy = Float(py)
                    // Convert influence radius from world to pixel space.
                    let influencePxF = rWorld / worldPerPxX
                    let influencePxF2 = influencePxF * influencePxF

                    for bj in by0...by1 {
                        for bi in bx0...bx1 {
                            for ci in bins[bi + bj * binsX] {
                                let c = projected[ci]
                                let dx = c.px - qx
                                let dy = c.py - qy
                                let d2 = dx * dx + dy * dy
                                if d2 > influencePxF2 { continue }
                                // Quadratic falloff metaball kernel.
                                // 1 - (d/r)² gives smooth peak at center.
                                let f = max(0, 1 - d2 / influencePxF2)
                                let wgt = f * f
                                field += wgt
                                if wgt > bestW {
                                    bestW = wgt
                                    bestColor = c.color
                                    bestEnergy = c.energy
                                }
                            }
                        }
                    }
                    _ = r2

                    if field > metaballThreshold {
                        // Inside the isosurface — solid color with a hint of
                        // central highlight from accumulated field strength.
                        let surface: Float = (field - metaballThreshold) / max(0.001, 1.5 - metaballThreshold)
                        let bright = min(1, 0.6 + surface * 0.7) * (0.85 + 0.25 * bestEnergy)
                        let outCol = bestColor * bright
                        let n = 4 * (px + py * w)
                        let r = Float(pixels[n + 0]) / 255
                        let g = Float(pixels[n + 1]) / 255
                        let b = Float(pixels[n + 2]) / 255
                        let alpha: Float = min(1, 0.55 + surface * 0.45)
                        pixels[n + 0] = toByte(r * (1 - alpha) + outCol.x * alpha)
                        pixels[n + 1] = toByte(g * (1 - alpha) + outCol.y * alpha)
                        pixels[n + 2] = toByte(b * (1 - alpha) + outCol.z * alpha)
                    } else if field > metaballThreshold * 0.5 {
                        // Outer membrane glow / soft edge.
                        let edge = (field - metaballThreshold * 0.5) / (metaballThreshold * 0.5)
                        let alpha: Float = edge * 0.35
                        let outCol = bestColor * 0.7
                        let n = 4 * (px + py * w)
                        let r = Float(pixels[n + 0]) / 255
                        let g = Float(pixels[n + 1]) / 255
                        let b = Float(pixels[n + 2]) / 255
                        pixels[n + 0] = toByte(r * (1 - alpha) + outCol.x * alpha)
                        pixels[n + 1] = toByte(g * (1 - alpha) + outCol.y * alpha)
                        pixels[n + 2] = toByte(b * (1 - alpha) + outCol.z * alpha)
                    }
                }
            }

            // Predation flashes still draw over.
            for ev in world.colony.recentPredations {
                let ageT = Float(ev.age) / Float(max(1, world.colony.predationEventLifetime))
                let alpha = max(0, 0.85 * (1 - ageT))
                let pa = SIMD2<Float>(ev.predator.x * pxPerUnit.x, ev.predator.y * pxPerUnit.y)
                let pb = SIMD2<Float>(ev.prey.x * pxPerUnit.x, ev.prey.y * pxPerUnit.y)
                drawLine(into: &pixels, w: w, h: h,
                         x0: pa.x, y0: pa.y, x1: pb.x, y1: pb.y,
                         color: SIMD3<Float>(1.0, 0.3, 0.2), alpha: alpha)
            }

            // Vignette.
            let cx = Float(w) * 0.5, cy = Float(h) * 0.5
            let maxR = sqrt(cx * cx + cy * cy)
            for py in 0..<h {
                for px in 0..<w {
                    let dx = Float(px) - cx
                    let dy = Float(py) - cy
                    let r = sqrt(dx * dx + dy * dy) / maxR
                    let vignette = 1 - r * r * 0.45
                    let n = 4 * (px + py * w)
                    pixels[n + 0] = toByte(Float(pixels[n + 0]) / 255 * vignette)
                    pixels[n + 1] = toByte(Float(pixels[n + 1]) / 255 * vignette)
                    pixels[n + 2] = toByte(Float(pixels[n + 2]) / 255 * vignette)
                }
            }

            return pixels
        }

        var sortedCells = world.colony.cells
        sortedCells.sort { $0.position.z < $1.position.z }
        for cell in sortedCells {
            let px = cell.position.x * pxPerUnit.x
            let py = cell.position.y * pxPerUnit.y
            let energyHeat = 1.0 - expf(-cell.energy * 0.5)
            let zNorm = max(0, min(1, cell.position.z / tankZ))
            let depthScale = 0.7 + 0.6 * zNorm
            let depthBright: Float = 0.55 + 0.45 * zNorm
            let radius = (cellRadiusPx + energyHeat * 2.5) * depthScale
            let core: SIMD3<Float>
            let glow: SIMD3<Float>
            switch colorMode {
            case .role:
                let p = max(0, roleP[cell.id] ?? 0)
                let m = max(0, roleC[cell.id] ?? 0)
                // Role mix: red for predation, orange for motor, green default.
                let predatorCol = SIMD3<Float>(1.0, 0.18, 0.18)
                let motorCol    = SIMD3<Float>(1.0, 0.55, 0.10)
                let structCol   = SIMD3<Float>(0.45, 0.95, 0.55)
                let pw = min(1, p * 1.6)
                let mw = min(1, m * 1.6)
                let totalW = pw + mw
                let baseCol: SIMD3<Float>
                if totalW < 0.05 {
                    baseCol = structCol
                } else {
                    let pn = pw / max(0.001, totalW)
                    let mn = mw / max(0.001, totalW)
                    let active = predatorCol * pn + motorCol * mn
                    baseCol = mix(structCol, active, t: min(1, totalW))
                }
                let glowC = baseCol * depthBright
                let coreC = mix(glowC, SIMD3<Float>(1, 1, 1), t: 0.55)
                core = coreC
                glow = glowC
            case .organism:
                let hue = organismHue(cell.organismId)
                let glowC = hsvToRgb(h: hue, s: 0.85, v: 1.0) * depthBright
                core = mix(glowC, SIMD3<Float>(1, 1, 1), t: 0.65)
                glow = glowC
            case .uniform:
                core = SIMD3<Float>(1.0, 0.95, 0.85) * depthBright
                glow = SIMD3<Float>(1.0, 0.55, 0.25) * depthBright
            }
            splat(into: &pixels, w: w, h: h, cx: px, cy: py, radius: radius,
                  core: core, glow: glow, energy: energyHeat)
        }

        // Predation flash: bright red arc from predator to prey for each
        // event in flight. Older events fade.
        for ev in world.colony.recentPredations {
            let ageT = Float(ev.age) / Float(max(1, world.colony.predationEventLifetime))
            let alpha = max(0, 0.85 * (1 - ageT))
            let pa = SIMD2<Float>(ev.predator.x * pxPerUnit.x, ev.predator.y * pxPerUnit.y)
            let pb = SIMD2<Float>(ev.prey.x * pxPerUnit.x, ev.prey.y * pxPerUnit.y)
            drawLine(into: &pixels, w: w, h: h,
                     x0: pa.x, y0: pa.y, x1: pb.x, y1: pb.y,
                     color: SIMD3<Float>(1.0, 0.25, 0.18), alpha: alpha)
        }

        // Final pass: subtle vignette + chromatic aberration. Pushes the image
        // toward "looking through a microscope eyepiece" without doing any
        // actual raytracing.
        let cx = Float(w) * 0.5, cy = Float(h) * 0.5
        let maxR = sqrt(cx * cx + cy * cy)
        for py in 0..<h {
            for px in 0..<w {
                let dx = Float(px) - cx
                let dy = Float(py) - cy
                let r = sqrt(dx * dx + dy * dy) / maxR
                let vignette = 1 - r * r * 0.55
                let n = 4 * (px + py * w)
                pixels[n + 0] = toByte(Float(pixels[n + 0]) / 255 * vignette)
                pixels[n + 1] = toByte(Float(pixels[n + 1]) / 255 * vignette)
                pixels[n + 2] = toByte(Float(pixels[n + 2]) / 255 * vignette)
            }
        }

        return pixels
    }

    /// Render and save PNG. Returns true on success.
    @discardableResult
    public func writePNG(_ world: World, to url: URL) -> Bool {
        let pixels = renderRGBA(world)
        return Self.writeRGBA8PNG(pixels: pixels, width: width, height: height, to: url)
    }

    /// Animated GIF from a sequence of RGBA8 frames. Each frame is a full
    /// pixel buffer of size `width * height * 4`. `frameDelay` is the delay
    /// between frames in seconds (GIF granularity is 1/100s, so values get
    /// rounded). `loopCount` of 0 means infinite loop.
    @discardableResult
    public static func writeAnimatedGIF(
        frames: [[UInt8]], width: Int, height: Int,
        frameDelay: Double, loopCount: Int = 0, to url: URL
    ) -> Bool {
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
              ) else { return false }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopCount
            ]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ]
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let info: CGBitmapInfo = [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        for frame in frames {
            guard let provider = CGDataProvider(data: Data(frame) as CFData),
                  let img = CGImage(
                    width: width, height: height,
                    bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4,
                    space: cs, bitmapInfo: info,
                    provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent
                  ) else { return false }
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
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

    private func drawLine(
        into pixels: inout [UInt8], w: Int, h: Int,
        x0: Float, y0: Float, x1: Float, y1: Float,
        color: SIMD3<Float>, alpha: Float
    ) {
        // Wu-ish: rasterise along the major axis with linear alpha for the
        // off-axis pixel. Cheap, good enough for thin bond lines.
        let dx = x1 - x0
        let dy = y1 - y0
        let steps = max(abs(dx), abs(dy))
        if steps < 0.5 { return }
        let n = Int(steps.rounded(.up))
        for s in 0...n {
            let t = Float(s) / Float(n)
            let x = x0 + dx * t
            let y = y0 + dy * t
            blendPixel(into: &pixels, w: w, h: h, x: x, y: y, color: color, alpha: alpha)
        }
    }

    @inline(__always)
    private func organismHue(_ id: UInt32) -> Float {
        // Cheap hash → [0, 1) hue.
        var x = id &* 2654435761
        x ^= x >> 16
        return Float(x & 0xFFFFFF) / Float(0x1000000)
    }

    private func hsvToRgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i.truncatingRemainder(dividingBy: 6)) {
        case 0: return SIMD3<Float>(v, t, p)
        case 1: return SIMD3<Float>(q, v, p)
        case 2: return SIMD3<Float>(p, v, t)
        case 3: return SIMD3<Float>(p, q, v)
        case 4: return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
        }
    }

    private func blendPixel(
        into pixels: inout [UInt8], w: Int, h: Int,
        x: Float, y: Float, color: SIMD3<Float>, alpha: Float
    ) {
        let xi = Int(x.rounded()), yi = Int(y.rounded())
        guard xi >= 0, xi < w, yi >= 0, yi < h else { return }
        let n = 4 * (xi + yi * w)
        let r = Float(pixels[n + 0]) / 255
        let g = Float(pixels[n + 1]) / 255
        let b = Float(pixels[n + 2]) / 255
        let a = min(1, max(0, alpha))
        pixels[n + 0] = toByte(r * (1 - a) + color.x * a)
        pixels[n + 1] = toByte(g * (1 - a) + color.y * a)
        pixels[n + 2] = toByte(b * (1 - a) + color.z * a)
        pixels[n + 3] = 255
    }
}
