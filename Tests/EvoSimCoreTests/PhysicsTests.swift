import XCTest
import simd
@testable import EvoSimCore

final class PhysicsTests: XCTestCase {
    func testBondPullsCellsTogetherWhenStretched() {
        var positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(4, 0, 0)]
        var velocities = [SIMD3<Float>](repeating: .zero, count: 2)
        var stress = [Float](repeating: 0, count: 2)
        var bonds = [Bond(a: 1, b: 2, restLength: 1.5, stiffness: 1.5)]
        let idIndex: [UInt32: Int] = [1: 0, 2: 1]
        var integrator = SoftBodyIntegrator()
        integrator.drag = 0.5  // less damping so movement is obvious in a short run

        let initialGap = simd_length(positions[1] - positions[0])
        for _ in 0..<60 {
            integrator.integrate(
                positions: &positions, velocities: &velocities, stress: &stress,
                bonds: &bonds, idIndex: idIndex,
                contraction: [Float](repeating: 0, count: positions.count),
                bounds: SIMD3<Float>(100, 100, 100), dt: 1.0 / 60.0
            )
        }
        let finalGap = simd_length(positions[1] - positions[0])
        XCTAssertLessThan(finalGap, initialGap, "stretched spring should shorten")
        // Stress should have been registered.
        XCTAssertGreaterThan(stress[0], 0)
        XCTAssertGreaterThan(stress[1], 0)
    }

    func testOverstretchedBondBreaks() {
        var positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(20, 0, 0)]
        var velocities = [SIMD3<Float>](repeating: .zero, count: 2)
        var stress = [Float](repeating: 0, count: 2)
        var bonds = [Bond(a: 1, b: 2, restLength: 1.5, stiffness: 1)]
        let idIndex: [UInt32: Int] = [1: 0, 2: 1]
        var integrator = SoftBodyIntegrator()
        // breakStretchRatio = 3.5, restLength 1.5 ⇒ break above 5.25 → 20 > 5.25.
        integrator.integrate(
            positions: &positions, velocities: &velocities, stress: &stress,
            bonds: &bonds, idIndex: idIndex,
            contraction: [Float](repeating: 0, count: positions.count),
            bounds: SIMD3<Float>(100, 100, 100), dt: 1.0 / 60.0
        )
        XCTAssertEqual(bonds.count, 0)
    }

    func testBoundaryReflectsCell() {
        var positions = [SIMD3<Float>(-2, 5, 5)]
        var velocities = [SIMD3<Float>(.zero)]
        var stress = [Float](repeating: 0, count: 1)
        var bonds: [Bond] = []
        let integrator = SoftBodyIntegrator()
        for _ in 0..<120 {
            integrator.integrate(
                positions: &positions, velocities: &velocities, stress: &stress,
                bonds: &bonds, idIndex: [:],
                contraction: [Float](repeating: 0, count: positions.count),
                bounds: SIMD3<Float>(10, 10, 10), dt: 1.0 / 60.0
            )
        }
        XCTAssertGreaterThanOrEqual(positions[0].x, -0.5)
    }

    func testContractionShortensBondEffectiveLength() {
        // Two cells exactly at rest length apart (zero stretch). With both
        // endpoints commanded to full +1 contraction, the bond's effective
        // rest length shortens and pulls them inward.
        var positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1.5, 0, 0)]
        var velocities = [SIMD3<Float>](repeating: .zero, count: 2)
        var stress = [Float](repeating: 0, count: 2)
        var bonds = [Bond(a: 1, b: 2, restLength: 1.5, stiffness: 2.0)]
        let idIndex: [UInt32: Int] = [1: 0, 2: 1]
        var integrator = SoftBodyIntegrator()
        integrator.drag = 0.4
        for _ in 0..<60 {
            integrator.integrate(
                positions: &positions, velocities: &velocities, stress: &stress,
                bonds: &bonds, idIndex: idIndex,
                contraction: [1.0, 1.0],
                bounds: SIMD3<Float>(100, 100, 100), dt: 1.0 / 60.0
            )
        }
        let gap = simd_length(positions[1] - positions[0])
        XCTAssertLessThan(gap, 1.5 - 1e-3, "contraction should pull bond shorter than nominal rest length")
    }

    func testDivisionCreatesBond() {
        // Construct a world, run until at least one division has happened.
        var w = World(seed: 314)
        w.seedRandomOrganisms(count: 4)
        w.sprinkleFood(count: 8)
        let bonds0 = w.colony.bonds.count
        for _ in 0..<300 { w.tick() }
        // Some lineage must have divided.
        let bonds1 = w.colony.bonds.count
        XCTAssertGreaterThan(bonds1, bonds0)
        // And those bonds endpoints should refer to live cells.
        let liveIds = Set(w.colony.cells.map { $0.id })
        for bond in w.colony.bonds {
            XCTAssertTrue(liveIds.contains(bond.a))
            XCTAssertTrue(liveIds.contains(bond.b))
        }
    }
}
