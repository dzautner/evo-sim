import simd

public struct World {
    public let bounds: SIMD3<Float>
    public let fixedDt: Double
    public private(set) var step: UInt64
    public private(set) var time: Double
    public var rng: Xoshiro256

    public init(
        bounds: SIMD3<Float> = SIMD3<Float>(100, 100, 100),
        fixedDt: Double = 1.0 / 60.0,
        seed: UInt64 = 0xC0FFEE
    ) {
        self.bounds = bounds
        self.fixedDt = fixedDt
        self.step = 0
        self.time = 0
        self.rng = Xoshiro256(seed: seed)
    }

    public mutating func tick() {
        step &+= 1
        time += fixedDt
    }
}
