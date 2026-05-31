import Foundation

/// Architecture of the per-organism neural network.
/// Fixed for all organisms in v0: only weights mutate. Future: topology
/// mutations (channels added/removed) can land here without changing call sites.
public struct GenomeShape: Equatable {
    public let inputSize: Int
    public let hidden: [Int]
    public let outputSize: Int

    public init(inputSize: Int, hidden: [Int], outputSize: Int) {
        precondition(inputSize > 0 && outputSize > 0 && !hidden.isEmpty)
        self.inputSize = inputSize
        self.hidden = hidden
        self.outputSize = outputSize
    }

    public var layerSizes: [Int] { [inputSize] + hidden + [outputSize] }

    /// Total weight + bias count.
    public var parameterCount: Int {
        var total = 0
        let sizes = layerSizes
        for i in 0..<(sizes.count - 1) {
            total += sizes[i] * sizes[i + 1]   // weights
            total += sizes[i + 1]              // biases
        }
        return total
    }
}

/// Index conventions for the input vector the NCA sees per cell.
/// Kept here (not hardcoded inside NCA) so we never embed magic numbers.
public enum NCAInput {
    /// Layout: [own state (stateCh) | mean neighbor state (stateCh) |
    ///          local chemistry vec (4: c, ∂c/∂x, ∂c/∂y, ∂c/∂z) |
    ///          mechanical stress (1) | bias (1)]
    public static let chemistryChannels = 4
    public static let auxChannels = 2  // stress + bias

    public static func size(stateChannels: Int) -> Int {
        2 * stateChannels + chemistryChannels + auxChannels
    }
}

/// Index conventions for the output vector the NCA emits per cell.
/// Outputs are passed through tanh, then interpreted by Colony.applyOutputs.
public enum NCAOutput {
    /// Layout: [Δstate (stateCh) | divide (1) | bud (1) | die (1) | divDir (3)]
    public static let divideIdx = 0   // after stateCh
    public static let budIdx    = 1
    public static let dieIdx    = 2
    public static let divDirIdx = 3   // 3 components

    public static let nonStateChannels = 6  // divide + bud + die + 3 dir

    public static func size(stateChannels: Int) -> Int {
        stateChannels + nonStateChannels
    }
}

/// A single organism's genome: the weights of its NCA. The whole multicellular
/// body shares this — every cell forward-passes through the same network.
/// Mutation is Gaussian noise on weights (uniform σ for v0).
public struct Genome {
    public let shape: GenomeShape
    public var weights: [Float]

    public init(shape: GenomeShape, weights: [Float]) {
        precondition(weights.count == shape.parameterCount,
                     "weight count \(weights.count) ≠ shape.parameterCount \(shape.parameterCount)")
        self.shape = shape
        self.weights = weights
    }

    /// Random genome with Glorot-ish init scaled small so initial behaviour is
    /// near-zero (cells mostly do nothing) — evolution discovers everything.
    public static func random(shape: GenomeShape, rng: inout Xoshiro256, gain: Float = 0.6) -> Genome {
        var w = [Float](repeating: 0, count: shape.parameterCount)
        let sizes = shape.layerSizes
        var cursor = 0
        for i in 0..<(sizes.count - 1) {
            let fanIn = sizes[i]
            let fanOut = sizes[i + 1]
            let scale = Float(gain) * (2.0 / Float(fanIn + fanOut)).squareRoot()
            for _ in 0..<(fanIn * fanOut) {
                w[cursor] = Float(rng.nextGaussian()) * scale
                cursor += 1
            }
            // Biases start small but nonzero so dead-zero plateaus get nudged.
            for _ in 0..<fanOut {
                w[cursor] = Float(rng.nextGaussian()) * 0.05
                cursor += 1
            }
        }
        return Genome(shape: shape, weights: w)
    }

    /// Asexual mutation: each weight perturbed by N(0, σ) independently with
    /// probability `rate`. Occasionally large "macro" jumps.
    public func mutated(rate: Float = 0.05, sigma: Float = 0.08, macroRate: Float = 0.002,
                        macroSigma: Float = 0.6, rng: inout Xoshiro256) -> Genome {
        var w = weights
        for i in 0..<w.count {
            if Float(rng.nextUnit()) < rate {
                w[i] += Float(rng.nextGaussian()) * sigma
            }
            if Float(rng.nextUnit()) < macroRate {
                w[i] += Float(rng.nextGaussian()) * macroSigma
            }
        }
        return Genome(shape: shape, weights: w)
    }
}
