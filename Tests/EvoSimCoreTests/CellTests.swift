import XCTest
import simd
@testable import EvoSimCore

final class CellTests: XCTestCase {
    func testColonySpawnAssignsUniqueIds() {
        var colony = Colony()
        let a = colony.spawn(at: .zero, lineageId: 1)
        let b = colony.spawn(at: SIMD3<Float>(1, 0, 0), lineageId: 1)
        let c = colony.spawn(at: SIMD3<Float>(2, 0, 0), lineageId: 2)
        XCTAssertEqual(colony.count, 3)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertEqual(colony.cells[0].lineageId, 1)
        XCTAssertEqual(colony.cells[2].lineageId, 2)
    }

    func testUptakeTransfersChemistryToCellEnergy() {
        var field = NutrientField(resolution: SIMD3<Int32>(16, 16, 16), cellSize: 1, diffusion: 0)
        field.deposit(at: SIMD3<Float>(8, 8, 8), amount: 20, sigma: 0.5)
        var colony = Colony(uptakeRate: 4.0)
        _ = colony.spawn(at: SIMD3<Float>(8.4, 8.4, 8.4), lineageId: 1)

        let chemBefore = field.totalMass
        let cellBefore = Double(colony.cells[0].energy)
        for _ in 0..<10 { colony.tick(dt: 1.0 / 60.0, chemistry: &field) }
        let chemAfter = field.totalMass
        let cellAfter = Double(colony.cells[0].energy)

        XCTAssertLessThan(chemAfter, chemBefore)
        XCTAssertGreaterThan(cellAfter, cellBefore)
        // Mass conservation: what cell gained == what chemistry lost.
        XCTAssertEqual(chemBefore - chemAfter, cellAfter - cellBefore, accuracy: 1e-4)
    }

    func testWorldTickConservesEnergyClosedTank() {
        var world = World(seed: 11)
        world.chemistry.deposit(at: SIMD3<Float>(24, 24, 24), amount: 100, sigma: 2.5)
        _ = world.colony.spawn(at: SIMD3<Float>(24, 24, 24), lineageId: 1)
        let total0 = world.totalEnergy
        for _ in 0..<300 { world.tick() }
        let total1 = world.totalEnergy
        XCTAssertEqual(total1, total0, accuracy: max(1e-2, abs(total0) * 1e-4))
    }
}
