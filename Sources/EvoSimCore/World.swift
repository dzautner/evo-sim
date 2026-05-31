import simd

public struct World {
    public let bounds: SIMD3<Float>
    public let fixedDt: Double
    public private(set) var step: UInt64
    public private(set) var time: Double
    public var rng: Xoshiro256
    public var chemistry: NutrientField
    public var colony: Colony

    public init(
        bounds: SIMD3<Float> = SIMD3<Float>(48, 48, 48),
        fixedDt: Double = 1.0 / 60.0,
        seed: UInt64 = 0xC0FFEE,
        chemistry: NutrientField = NutrientField(),
        colony: Colony = Colony()
    ) {
        self.bounds = bounds
        self.fixedDt = fixedDt
        self.step = 0
        self.time = 0
        self.rng = Xoshiro256(seed: seed)
        self.chemistry = chemistry
        self.colony = colony
    }

    public mutating func tick() {
        let dt = Float(fixedDt)
        // Order is important for mass conservation tests:
        // cells uptake from CURRENT chemistry, then chemistry diffuses.
        colony.tick(dt: dt, chemistry: &chemistry)
        chemistry.diffuse(dt: dt)
        step &+= 1
        time += fixedDt
    }

    /// Total nutrient + cell energy. Conserved in a closed tank with no decay,
    /// no sources, and no death (Phase 1 invariant).
    public var totalEnergy: Double {
        var sum = chemistry.totalMass
        for c in colony.cells { sum += Double(c.energy) }
        return sum
    }
}
