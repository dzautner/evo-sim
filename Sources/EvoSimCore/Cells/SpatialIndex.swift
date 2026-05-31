import simd

/// Uniform-grid spatial hash for O(1)-ish radius queries over cells.
/// Rebuilt once per tick from current cell positions.
public struct SpatialIndex {
    public let cellSize: Float
    public let resolution: SIMD3<Int32>
    /// Flat array of cell-indices per bucket. `bucketStart[i]` … `bucketStart[i+1]`.
    @usableFromInline var bucketStart: [Int32]
    @usableFromInline var cellIndices: [Int32]

    public init(cellSize: Float, worldExtent: SIMD3<Float>) {
        self.cellSize = max(cellSize, 0.001)
        let res = SIMD3<Int32>(
            max(1, Int32((worldExtent.x / cellSize).rounded(.up))),
            max(1, Int32((worldExtent.y / cellSize).rounded(.up))),
            max(1, Int32((worldExtent.z / cellSize).rounded(.up)))
        )
        self.resolution = res
        let n = Int(res.x) * Int(res.y) * Int(res.z)
        self.bucketStart = [Int32](repeating: 0, count: n + 1)
        self.cellIndices = []
    }

    @inlinable
    func bucketIndex(for p: SIMD3<Float>) -> Int? {
        let nx = Int(resolution.x), ny = Int(resolution.y), nz = Int(resolution.z)
        let i = Int((p.x / cellSize).rounded(.down))
        let j = Int((p.y / cellSize).rounded(.down))
        let k = Int((p.z / cellSize).rounded(.down))
        guard i >= 0, i < nx, j >= 0, j < ny, k >= 0, k < nz else { return nil }
        return i + nx * (j + ny * k)
    }

    public mutating func rebuild(positions: [SIMD3<Float>]) {
        let bucketCount = bucketStart.count - 1
        // Count per bucket.
        for n in 0..<bucketStart.count { bucketStart[n] = 0 }
        for p in positions {
            if let b = bucketIndex(for: p) { bucketStart[b] &+= 1 }
        }
        // Prefix sum → starts.
        var run: Int32 = 0
        for i in 0..<bucketCount {
            let c = bucketStart[i]
            bucketStart[i] = run
            run &+= c
        }
        bucketStart[bucketCount] = run
        cellIndices = [Int32](repeating: -1, count: Int(run))
        // Place. Use a separate cursor per bucket (consumes counts back).
        var cursor = [Int32](repeating: 0, count: bucketCount)
        for (idx, p) in positions.enumerated() {
            guard let b = bucketIndex(for: p) else { continue }
            let slot = Int(bucketStart[b] + cursor[b])
            cellIndices[slot] = Int32(idx)
            cursor[b] &+= 1
        }
    }

    /// Visit cell indices within `radius` of `p`. Slightly over-broad
    /// (visits buckets whose AABB intersects the sphere), caller filters by d².
    @inlinable
    public func forEachNeighbor(of p: SIMD3<Float>, radius: Float, _ body: (Int) -> Void) {
        let nx = Int(resolution.x), ny = Int(resolution.y), nz = Int(resolution.z)
        let r = Int((radius / cellSize).rounded(.up))
        let ci = Int((p.x / cellSize).rounded(.down))
        let cj = Int((p.y / cellSize).rounded(.down))
        let ck = Int((p.z / cellSize).rounded(.down))
        let x0 = max(0, ci - r), x1 = min(nx - 1, ci + r)
        let y0 = max(0, cj - r), y1 = min(ny - 1, cj + r)
        let z0 = max(0, ck - r), z1 = min(nz - 1, ck + r)
        if x0 > x1 || y0 > y1 || z0 > z1 { return }
        for kk in z0...z1 {
            for jj in y0...y1 {
                for ii in x0...x1 {
                    let b = ii + nx * (jj + ny * kk)
                    let s = Int(bucketStart[b])
                    let e = Int(bucketStart[b + 1])
                    for n in s..<e { body(Int(cellIndices[n])) }
                }
            }
        }
    }
}
