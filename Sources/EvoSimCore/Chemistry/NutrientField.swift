import simd

/// 3D scalar field of nutrient concentration. Diffusion via 7-point stencil
/// (Laplacian), reflective boundaries (zero flux), optional uniform decay.
/// Mass-conserving with no decay and no sources/sinks.
public struct NutrientField {
    public let resolution: SIMD3<Int32>
    public let cellSize: Float
    public var diffusion: Float
    public var decay: Float

    @usableFromInline var concentration: [Float]
    @usableFromInline var scratch: [Float]

    public init(
        resolution: SIMD3<Int32> = SIMD3<Int32>(48, 48, 48),
        cellSize: Float = 1.0,
        diffusion: Float = 0.12,
        decay: Float = 0.0
    ) {
        precondition(resolution.x > 0 && resolution.y > 0 && resolution.z > 0)
        self.resolution = resolution
        self.cellSize = cellSize
        self.diffusion = diffusion
        self.decay = decay
        let count = Int(resolution.x) * Int(resolution.y) * Int(resolution.z)
        self.concentration = [Float](repeating: 0, count: count)
        self.scratch = [Float](repeating: 0, count: count)
    }

    @inlinable
    public var nx: Int { Int(resolution.x) }
    @inlinable
    public var ny: Int { Int(resolution.y) }
    @inlinable
    public var nz: Int { Int(resolution.z) }

    @inlinable
    public func index(_ i: Int, _ j: Int, _ k: Int) -> Int {
        i + nx * (j + ny * k)
    }

    public func sample(at i: Int, _ j: Int, _ k: Int) -> Float {
        guard i >= 0, i < nx, j >= 0, j < ny, k >= 0, k < nz else { return 0 }
        return concentration[index(i, j, k)]
    }

    /// Convert continuous world-space position to integer grid index.
    /// Returns nil if outside the field bounds.
    public func gridIndex(for position: SIMD3<Float>) -> (i: Int, j: Int, k: Int)? {
        let g = position / cellSize
        let i = Int(g.x.rounded(.down))
        let j = Int(g.y.rounded(.down))
        let k = Int(g.z.rounded(.down))
        guard i >= 0, i < nx, j >= 0, j < ny, k >= 0, k < nz else { return nil }
        return (i, j, k)
    }

    /// Total integrated concentration. Useful for mass-conservation tests.
    public var totalMass: Double {
        var sum = 0.0
        for v in concentration { sum += Double(v) }
        return sum * Double(cellSize * cellSize * cellSize)
    }

    /// Inject a Gaussian blob of nutrient centered at world position.
    public mutating func deposit(at position: SIMD3<Float>, amount: Float, sigma: Float) {
        guard sigma > 0 else { return }
        let radius = max(1, Int((3 * sigma / cellSize).rounded(.up)))
        let center = position / cellSize
        let ci = Int(center.x.rounded()), cj = Int(center.y.rounded()), ck = Int(center.z.rounded())
        let inv2s2 = 1 / (2 * sigma * sigma)
        var weights: [Float] = []
        var indices: [Int] = []
        weights.reserveCapacity((2 * radius + 1) * (2 * radius + 1) * (2 * radius + 1))
        indices.reserveCapacity(weights.capacity)
        var totalW: Float = 0
        for dk in -radius...radius {
            let k = ck + dk
            guard k >= 0, k < nz else { continue }
            for dj in -radius...radius {
                let j = cj + dj
                guard j >= 0, j < ny else { continue }
                for di in -radius...radius {
                    let i = ci + di
                    guard i >= 0, i < nx else { continue }
                    let dx = Float(di) * cellSize
                    let dy = Float(dj) * cellSize
                    let dz = Float(dk) * cellSize
                    let r2 = dx * dx + dy * dy + dz * dz
                    let w = expf(-r2 * inv2s2)
                    weights.append(w)
                    indices.append(index(i, j, k))
                    totalW += w
                }
            }
        }
        guard totalW > 0 else { return }
        let scale = amount / totalW
        for (n, idx) in indices.enumerated() {
            concentration[idx] += weights[n] * scale
        }
    }

    /// Diffusion step using forward Euler on the 7-point Laplacian.
    /// Coefficient α = diffusion * dt / cellSize². Stability: α ≤ 1/6 in 3D.
    public mutating func diffuse(dt: Float) {
        let alpha = diffusion * dt / (cellSize * cellSize)
        // Clamp for safety; if user pushes diffusion too high we still don't blow up.
        let a = min(alpha, 1.0 / 6.0)
        let decayMul = max(0.0, 1.0 - decay * dt)
        let nx = self.nx, ny = self.ny, nz = self.nz
        concentration.withUnsafeBufferPointer { src in
            scratch.withUnsafeMutableBufferPointer { dst in
                for k in 0..<nz {
                    let zBack = max(k - 1, 0)
                    let zFwd = min(k + 1, nz - 1)
                    for j in 0..<ny {
                        let yBack = max(j - 1, 0)
                        let yFwd = min(j + 1, ny - 1)
                        let rowBase = nx * (j + ny * k)
                        for i in 0..<nx {
                            let xBack = max(i - 1, 0)
                            let xFwd = min(i + 1, nx - 1)
                            let c = src[i + rowBase]
                            let neigh = src[xBack + rowBase]
                                + src[xFwd + rowBase]
                                + src[i + nx * (yBack + ny * k)]
                                + src[i + nx * (yFwd + ny * k)]
                                + src[i + nx * (j + ny * zBack)]
                                + src[i + nx * (j + ny * zFwd)]
                            dst[i + rowBase] = (c + a * (neigh - 6 * c)) * decayMul
                        }
                    }
                }
            }
        }
        swap(&concentration, &scratch)
    }

    /// Subtract from a single grid cell; clamps at zero.
    /// Returns the amount actually removed.
    @discardableResult
    public mutating func uptake(at i: Int, _ j: Int, _ k: Int, amount: Float) -> Float {
        guard i >= 0, i < nx, j >= 0, j < ny, k >= 0, k < nz else { return 0 }
        let idx = index(i, j, k)
        let available = concentration[idx]
        let taken = min(available, max(0, amount))
        concentration[idx] = available - taken
        return taken
    }

    /// Read-only buffer view for renderers.
    public func withConcentration<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R {
        concentration.withUnsafeBufferPointer(body)
    }
}
