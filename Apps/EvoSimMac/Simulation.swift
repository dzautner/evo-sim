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
    private let maxStepsPerPump = 64

    init() {
        var w = World(seed: 0xC0FFEE)
        // Bootstrap food + one seed cell so the empty tank isn't literally empty
        // during dev. The NCA in Phase 2 will spawn cells via division instead.
        let extent = SIMD3<Float>(
            Float(w.chemistry.nx) * w.chemistry.cellSize,
            Float(w.chemistry.ny) * w.chemistry.cellSize,
            Float(w.chemistry.nz) * w.chemistry.cellSize
        )
        let center = extent * 0.5
        for _ in 0..<8 {
            let p = SIMD3<Float>(
                Float(w.rng.nextUnit()) * extent.x,
                Float(w.rng.nextUnit()) * extent.y,
                Float(w.rng.nextUnit()) * extent.z
            )
            w.chemistry.deposit(at: p, amount: 50, sigma: 3.0)
        }
        _ = w.colony.spawn(at: center, lineageId: 1)
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
        world.chemistry.deposit(at: SIMD3<Float>(fx, fy, fz), amount: 80, sigma: 3.5)
    }

    private func pump() {
        let now = CACurrentMediaTime()
        let realDt = now - lastHostTime
        lastHostTime = now
        guard !isPaused else { accumulator = 0; stepsLastPump = 0; return }

        accumulator += realDt * speedMultiplier
        var stepped = 0
        while accumulator >= world.fixedDt && stepped < maxStepsPerPump {
            world.tick()
            accumulator -= world.fixedDt
            stepped += 1
        }
        if stepped == maxStepsPerPump { accumulator = 0 }
        stepsLastPump = stepped
    }
}
