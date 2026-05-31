import XCTest
import simd
@testable import EvoSimCore

final class ChemistryTests: XCTestCase {
    func testDiffusionConservesMassClosedTank() {
        var field = NutrientField(resolution: SIMD3<Int32>(32, 32, 32), diffusion: 0.15, decay: 0)
        field.deposit(at: SIMD3<Float>(16, 16, 16), amount: 100, sigma: 2)
        let m0 = field.totalMass
        XCTAssertGreaterThan(m0, 0)
        for _ in 0..<200 { field.diffuse(dt: 1.0 / 60.0) }
        let m1 = field.totalMass
        // Reflective boundaries + symmetric stencil ⇒ mass conserved within fp noise.
        XCTAssertEqual(m1, m0, accuracy: max(1e-2, abs(m0) * 1e-4))
    }

    func testDiffusionSpreadsMass() {
        var field = NutrientField(resolution: SIMD3<Int32>(32, 32, 32), diffusion: 0.15, decay: 0)
        field.deposit(at: SIMD3<Float>(16, 16, 16), amount: 100, sigma: 0.6)
        let peak0 = field.sample(at: 16, 16, 16)
        for _ in 0..<200 { field.diffuse(dt: 1.0 / 60.0) }
        let peak1 = field.sample(at: 16, 16, 16)
        XCTAssertLessThan(peak1, peak0, "diffusion should lower the peak as mass spreads")
        // And the periphery should rise.
        XCTAssertGreaterThan(field.sample(at: 20, 16, 16), 0.0)
    }

    func testDecayMonotonicallyShrinksMass() {
        var field = NutrientField(resolution: SIMD3<Int32>(16, 16, 16), diffusion: 0.05, decay: 0.5)
        field.deposit(at: SIMD3<Float>(8, 8, 8), amount: 50, sigma: 1.5)
        let m0 = field.totalMass
        for _ in 0..<60 { field.diffuse(dt: 1.0 / 60.0) }
        let m1 = field.totalMass
        XCTAssertLessThan(m1, m0)
        XCTAssertGreaterThan(m1, 0)
    }

    func testGridIndexOutOfBoundsReturnsNil() {
        let field = NutrientField(resolution: SIMD3<Int32>(8, 8, 8), cellSize: 1)
        XCTAssertNotNil(field.gridIndex(for: SIMD3<Float>(0.5, 0.5, 0.5)))
        XCTAssertNil(field.gridIndex(for: SIMD3<Float>(-1, 4, 4)))
        XCTAssertNil(field.gridIndex(for: SIMD3<Float>(4, 4, 8.1)))
    }

    func testUptakeRemovesNutrientAndClamps() {
        var field = NutrientField(resolution: SIMD3<Int32>(8, 8, 8))
        field.deposit(at: SIMD3<Float>(4, 4, 4), amount: 30, sigma: 0.5)
        let before = field.sample(at: 4, 4, 4)
        XCTAssertGreaterThan(before, 0)
        let taken = field.uptake(at: 4, 4, 4, amount: before * 10)
        XCTAssertEqual(taken, before, accuracy: 1e-6)
        XCTAssertEqual(field.sample(at: 4, 4, 4), 0, accuracy: 1e-6)
    }
}
