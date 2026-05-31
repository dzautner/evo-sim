import XCTest
import simd
@testable import EvoSimCore

final class CellTests: XCTestCase {
    func testSeedRandomOrganismsCreatesIndependentGenomes() {
        var w = World(seed: 11)
        w.seedRandomOrganisms(count: 5)
        XCTAssertEqual(w.colony.organismCount, 5)
        XCTAssertEqual(w.colony.count, 5)
        // Pairwise genome difference (random init shouldn't collide).
        let weights = w.colony.organisms.values.map { $0.genome.weights }
        for i in 0..<weights.count {
            for j in (i + 1)..<weights.count {
                XCTAssertNotEqual(weights[i], weights[j])
            }
        }
    }

    func testColonyTickWithNoFoodKillsEverything() {
        var w = World(seed: 7)
        w.seedRandomOrganisms(count: 10)
        // No food in the tank: metabolic cost must eventually wipe out the
        // colony. Run long enough that even lineages that occasionally divide
        // (paying division cost) eventually starve.
        for _ in 0..<5000 { w.tick() }
        XCTAssertEqual(w.colony.count, 0)
    }

    func testDeterministicWithFixedSeed() {
        var a = World(seed: 1337)
        var b = World(seed: 1337)
        a.seedRandomOrganisms(count: 4)
        b.seedRandomOrganisms(count: 4)
        a.sprinkleFood(count: 6, amount: 220, sigma: 4.5)
        b.sprinkleFood(count: 6, amount: 220, sigma: 4.5)
        for _ in 0..<300 { a.tick(); b.tick() }
        XCTAssertEqual(a.colony.count, b.colony.count)
        XCTAssertEqual(a.totalEnergy, b.totalEnergy, accuracy: 1e-3)
    }

    func testDifferentSeedsDivergeIntoDifferentPopulations() {
        var a = World(seed: 1)
        var b = World(seed: 2)
        a.seedRandomOrganisms(count: 8)
        b.seedRandomOrganisms(count: 8)
        for _ in 0..<3 { a.sprinkleFood(count: 6, amount: 220, sigma: 4.5); b.sprinkleFood(count: 6, amount: 220, sigma: 4.5) }
        for n in 0..<1200 {
            if n % 200 == 199 { a.sprinkleFood(count: 4); b.sprinkleFood(count: 4) }
            a.tick(); b.tick()
        }
        // We don't require any particular outcome (extinction is allowed) but
        // different seeds shouldn't accidentally converge to the same state.
        XCTAssertNotEqual(a.colony.count == b.colony.count && a.totalEnergy == b.totalEnergy, true)
    }
}
