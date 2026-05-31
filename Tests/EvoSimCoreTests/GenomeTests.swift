import XCTest
@testable import EvoSimCore

final class GenomeTests: XCTestCase {
    private func shape() -> GenomeShape {
        let stateCh = Cell.stateChannelCount
        return GenomeShape(
            inputSize: NCAInput.size(stateChannels: stateCh),
            hidden: [32, 24],
            outputSize: NCAOutput.size(stateChannels: stateCh)
        )
    }

    func testParameterCountMatchesArchitecture() {
        let s = shape()
        // Input → 32 → 24 → output, with biases on each non-input layer.
        let expected = s.inputSize * 32 + 32 + 32 * 24 + 24 + 24 * s.outputSize + s.outputSize
        XCTAssertEqual(s.parameterCount, expected)
    }

    func testRandomGenomeHasCorrectSize() {
        var rng = Xoshiro256(seed: 0)
        let g = Genome.random(shape: shape(), rng: &rng)
        XCTAssertEqual(g.weights.count, shape().parameterCount)
    }

    func testNCAForwardOutputSize() {
        var rng = Xoshiro256(seed: 1)
        let g = Genome.random(shape: shape(), rng: &rng)
        var input = [Float](repeating: 0, count: g.shape.inputSize)
        for i in 0..<input.count { input[i] = Float(i) * 0.01 }
        var output = [Float](repeating: 0, count: g.shape.outputSize)
        var ws = NCA.Workspace(shape: g.shape)
        NCA.forward(genome: g, input: input, output: &output, workspace: &ws)
        XCTAssertEqual(output.count, g.shape.outputSize)
        // tanh outputs in (-1, 1).
        for v in output { XCTAssertGreaterThan(v, -1); XCTAssertLessThan(v, 1) }
    }

    func testNCAForwardDeterministic() {
        var rng = Xoshiro256(seed: 7)
        let g = Genome.random(shape: shape(), rng: &rng)
        var input = [Float](repeating: 0.2, count: g.shape.inputSize)
        var o1 = [Float](repeating: 0, count: g.shape.outputSize)
        var o2 = [Float](repeating: 0, count: g.shape.outputSize)
        var w1 = NCA.Workspace(shape: g.shape)
        var w2 = NCA.Workspace(shape: g.shape)
        NCA.forward(genome: g, input: input, output: &o1, workspace: &w1)
        for i in 0..<input.count { input[i] = 0.2 }
        NCA.forward(genome: g, input: input, output: &o2, workspace: &w2)
        XCTAssertEqual(o1, o2)
    }

    func testMutationChangesSomeWeights() {
        var rng = Xoshiro256(seed: 11)
        let parent = Genome.random(shape: shape(), rng: &rng)
        let child = parent.mutated(rate: 0.5, sigma: 0.1, rng: &rng)
        XCTAssertEqual(parent.weights.count, child.weights.count)
        var changed = 0
        for i in 0..<parent.weights.count where parent.weights[i] != child.weights[i] {
            changed += 1
        }
        XCTAssertGreaterThan(changed, parent.weights.count / 4)
    }
}
