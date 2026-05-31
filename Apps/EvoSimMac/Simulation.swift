import Foundation
import QuartzCore
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
    private let maxStepsPerPump = 32

    init() {
        self.world = World(seed: 0xC0FFEE)
    }

    func start() {
        lastHostTime = CACurrentMediaTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
