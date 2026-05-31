import XCTest
import simd
@testable import EvoSimCore

final class WorldTests: XCTestCase {
    func testTickAdvancesStepAndTime() {
        var w = World(bounds: SIMD3<Float>(10, 10, 10), seed: 1)
        XCTAssertEqual(w.step, 0)
        XCTAssertEqual(w.time, 0, accuracy: 1e-12)
        w.tick()
        XCTAssertEqual(w.step, 1)
        XCTAssertEqual(w.time, w.fixedDt, accuracy: 1e-12)
        for _ in 0..<99 { w.tick() }
        XCTAssertEqual(w.step, 100)
        XCTAssertEqual(w.time, w.fixedDt * 100, accuracy: 1e-9)
    }

    func testRngDeterminism() {
        var a = Xoshiro256(seed: 42)
        var b = Xoshiro256(seed: 42)
        for _ in 0..<1000 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func testRngDifferentSeedsDiverge() {
        var a = Xoshiro256(seed: 42)
        var b = Xoshiro256(seed: 43)
        var anyDifferent = false
        for _ in 0..<8 where a.next() != b.next() { anyDifferent = true }
        XCTAssertTrue(anyDifferent)
    }

    func testRngUnitInRange() {
        var r = Xoshiro256(seed: 7)
        for _ in 0..<10_000 {
            let u = r.nextUnit()
            XCTAssertGreaterThanOrEqual(u, 0)
            XCTAssertLessThan(u, 1)
        }
    }

    func testRngGaussianRoughlyCentered() {
        var r = Xoshiro256(seed: 99)
        var sum = 0.0
        let n = 20_000
        for _ in 0..<n { sum += r.nextGaussian() }
        let mean = sum / Double(n)
        XCTAssertEqual(mean, 0.0, accuracy: 0.05)
    }
}
