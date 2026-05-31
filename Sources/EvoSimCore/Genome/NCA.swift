import simd

/// Forward pass through a Genome's MLP. Stateless — pure function of
/// (genome, input). Uses tanh hidden activations and tanh output.
/// Allocations are reused via the workspace buffers passed in by the caller
/// so the per-cell hot loop in Colony.tick stays alloc-free.
public struct NCA {

    /// Pre-allocated scratch buffers sized for one organism's genome.
    /// One per organism; passed into `forward` to avoid per-cell allocation.
    public struct Workspace {
        public var a: [Float]   // current layer activations
        public var b: [Float]   // next layer activations

        public init(shape: GenomeShape) {
            let maxLayer = shape.layerSizes.max() ?? 0
            self.a = [Float](repeating: 0, count: max(maxLayer, shape.outputSize))
            self.b = [Float](repeating: 0, count: max(maxLayer, shape.outputSize))
        }
    }

    /// Forward pass. `input.count` must equal `genome.shape.inputSize`.
    /// Output is written into `output[0..<genome.shape.outputSize]`.
    @inlinable
    public static func forward(
        genome: Genome,
        input: [Float],
        output: inout [Float],
        workspace: inout Workspace
    ) {
        let sizes = genome.shape.layerSizes
        precondition(input.count == sizes[0])

        // Seed activations with input.
        for i in 0..<sizes[0] { workspace.a[i] = input[i] }

        var cursor = 0
        let nLayers = sizes.count - 1
        for li in 0..<nLayers {
            let fanIn = sizes[li]
            let fanOut = sizes[li + 1]
            // W: fanIn × fanOut, then biases length fanOut.
            for o in 0..<fanOut {
                var acc: Float = 0
                let wBase = cursor + o * fanIn
                for k in 0..<fanIn {
                    acc += genome.weights[wBase + k] * workspace.a[k]
                }
                let bias = genome.weights[cursor + fanIn * fanOut + o]
                workspace.b[o] = tanhf(acc + bias)
            }
            cursor += fanIn * fanOut + fanOut
            // Swap; we never mutate genome.weights.
            for o in 0..<fanOut { workspace.a[o] = workspace.b[o] }
        }

        let outN = sizes[sizes.count - 1]
        for o in 0..<outN { output[o] = workspace.a[o] }
    }
}
