import Foundation

public protocol RandomSource {
    mutating func next() -> UInt64
    mutating func nextUnit() -> Double
    mutating func nextGaussian() -> Double
}

public struct Xoshiro256: RandomSource {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64

    public init(seed: UInt64) {
        var z = seed == 0 ? 0xDEADBEEF_CAFEBABE : seed
        func splitmix() -> UInt64 {
            z = z &+ 0x9E3779B97F4A7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
            x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
            return x ^ (x >> 31)
        }
        s0 = splitmix()
        s1 = splitmix()
        s2 = splitmix()
        s3 = splitmix()
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    public mutating func next() -> UInt64 {
        let result = Self.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = Self.rotl(s3, 45)
        return result
    }

    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / Double(1 << 53))
    }

    public mutating func nextGaussian() -> Double {
        let u1 = max(nextUnit(), 1e-300)
        let u2 = nextUnit()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
    }
}
