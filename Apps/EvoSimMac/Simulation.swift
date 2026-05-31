import Foundation
import QuartzCore
import simd
import EvoSimCore

@MainActor
final class Simulation: ObservableObject {
    @Published private(set) var world: World
    @Published var speedMultiplier: Double = 1.0
    @Published var isPaused: Bool = false
    @Published private(set) var stepsLastPump: Int = 0

    private var timer: Timer?
    private var lastHostTime: CFTimeInterval = 0
    private var accumulator: Double = 0
    private var ticksSinceLastSprinkle: Int = 0
    private let maxStepsPerPump = 128

    init(initialOrganisms: Int = 24, seed: UInt64 = 0xC0FFEE) {
        var w = World(seed: seed)
        w.seedRandomOrganisms(count: initialOrganisms)
        w.sprinkleFood(count: 10, amount: 220, sigma: 4.5)
        self.world = w
    }

    func start() {
        lastHostTime = CACurrentMediaTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func dropFoodAtScreenPoint(_ p: CGPoint, in size: CGSize) {
        let extent = SIMD3<Float>(
            Float(world.chemistry.nx) * world.chemistry.cellSize,
            Float(world.chemistry.ny) * world.chemistry.cellSize,
            Float(world.chemistry.nz) * world.chemistry.cellSize
        )
        let fx = Float(p.x / size.width) * extent.x
        let fy = Float(p.y / size.height) * extent.y
        let fz = extent.z * 0.5
        world.chemistry.deposit(at: SIMD3<Float>(fx, fy, fz), amount: 90, sigma: 3.5)
    }

    func reseed(organisms n: Int = 24) {
        var w = World(seed: UInt64.random(in: 1...UInt64.max))
        w.seedRandomOrganisms(count: n)
        w.sprinkleFood(count: 10, amount: 220, sigma: 4.5)
        world = w
    }

    private func pump() {
        let now = CACurrentMediaTime()
        let realDt = now - lastHostTime
        lastHostTime = now
        guard !isPaused else { accumulator = 0; stepsLastPump = 0; return }

        accumulator += realDt * speedMultiplier
        var stepped = 0
        while accumulator >= world.fixedDt && stepped < maxStepsPerPump {
            ticksSinceLastSprinkle += 1
            if ticksSinceLastSprinkle >= 240 {
                world.sprinkleFood(count: 4)
                ticksSinceLastSprinkle = 0
            }
            world.tick()
            accumulator -= world.fixedDt
            stepped += 1
        }
        if stepped == maxStepsPerPump { accumulator = 0 }
        stepsLastPump = stepped
    }
}
