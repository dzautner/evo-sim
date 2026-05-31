import simd

public struct World {
    public let bounds: SIMD3<Float>
    public let fixedDt: Double
    public private(set) var step: UInt64
    public private(set) var time: Double
    public var rng: Xoshiro256
    public var chemistry: NutrientField
    public var colony: Colony
    public var spatial: SpatialIndex

    public let genomeShape: GenomeShape

    public init(
        bounds: SIMD3<Float> = SIMD3<Float>(48, 48, 48),
        fixedDt: Double = 1.0 / 60.0,
        seed: UInt64 = 0xC0FFEE,
        chemistry: NutrientField = NutrientField(),
        colony: Colony = Colony(),
        genomeShape: GenomeShape? = nil
    ) {
        self.bounds = bounds
        self.fixedDt = fixedDt
        self.step = 0
        self.time = 0
        self.rng = Xoshiro256(seed: seed)
        self.chemistry = chemistry
        self.colony = colony
        let stateCh = Cell.stateChannelCount
        self.genomeShape = genomeShape ?? GenomeShape(
            inputSize: NCAInput.size(stateChannels: stateCh),
            hidden: [32, 24],
            outputSize: NCAOutput.size(stateChannels: stateCh)
        )
        // Spatial index sized for neighbor radius; will fit ≥ all probable
        // bucket queries because cells live in `bounds`.
        self.spatial = SpatialIndex(cellSize: 2.0, worldExtent: bounds)
    }

    public mutating func tick() {
        let dt = Float(fixedDt)
        colony.tick(dt: dt, chemistry: &chemistry, index: &spatial, bounds: bounds, rng: &rng)
        chemistry.diffuse(dt: dt)
        step &+= 1
        time += fixedDt
    }

    /// Total nutrient + cell energy. NOT conserved post-Phase 2 because the
    /// genome can spend energy on division (constant cost) and metabolism
    /// constantly drains it. Used as a coarse population-health metric.
    public var totalEnergy: Double {
        var sum = chemistry.totalMass
        for c in colony.cells { sum += Double(c.energy) }
        return sum
    }

    /// Convenience: seed `n` independent organisms (each with a random
    /// genome) at random positions within the tank. Each starts as one cell.
    public mutating func seedRandomOrganisms(count n: Int) {
        for _ in 0..<n {
            // Higher init gain ⇒ greater behavioural variance at t=0 so
            // selection has something to operate on. Lineages with too-hot
            // genomes (constant divide, immediate suicide) die out fast.
            let genome = Genome.random(shape: genomeShape, rng: &rng, gain: 1.6)
            let oid = colony.registerOrganism(genome: genome)
            let p = SIMD3<Float>(
                Float(rng.nextUnit()) * bounds.x,
                Float(rng.nextUnit()) * bounds.y,
                Float(rng.nextUnit()) * bounds.z
            )
            colony.spawn(at: p, organismId: oid, initialEnergy: 1.4)
        }
    }

    /// Hand action: stir cells within `radius` of `at`, applying a radial
    /// outward impulse. Pure physics — equivalent to dragging a finger
    /// through a tank of water.
    public mutating func stirAt(_ at: SIMD3<Float>, radius: Float, strength: Float) {
        for i in 0..<colony.cells.count {
            let dp = colony.cells[i].position - at
            let d = simd_length(dp)
            if d < radius && d > 1e-3 {
                let dir = dp / d
                let falloff = max(0, 1 - d / radius)
                colony.applyImpulse(at: i, impulse: dir * strength * falloff)
            }
        }
    }

    /// Hand action: pluck the cell nearest `at` (within `radius`) — kills it
    /// and any bonds it's part of are cleaned up next tick.
    @discardableResult
    public mutating func pluckNearest(_ at: SIMD3<Float>, radius: Float) -> Bool {
        var bestIdx = -1
        var bestD2: Float = .greatestFiniteMagnitude
        for (i, c) in colony.cells.enumerated() {
            let d2 = simd_distance_squared(c.position, at)
            if d2 < bestD2 { bestD2 = d2; bestIdx = i }
        }
        if bestIdx >= 0, bestD2 <= radius * radius {
            colony.killCell(atIndex: bestIdx)
            return true
        }
        return false
    }

    /// Deposit `n` Gaussian food blobs at random positions. Call periodically
    /// from the snapshot CLI / app to keep the tank fed.
    public mutating func sprinkleFood(count n: Int, amount: Float = 220, sigma: Float = 4.5) {
        for _ in 0..<n {
            let p = SIMD3<Float>(
                Float(rng.nextUnit()) * bounds.x,
                Float(rng.nextUnit()) * bounds.y,
                Float(rng.nextUnit()) * bounds.z
            )
            chemistry.deposit(at: p, amount: amount, sigma: sigma)
        }
    }
}
