import Foundation
import simd
import EvoSimCore
import EvoSimRender

// CLI: run the sim for N steps from a seed, write a PNG snapshot.
// Optional trail: capture each cell's last K positions, render them as
// fading dots behind the live cells so locomotion is visible in a still.
//
// Usage:
//   swift run EvoSimSnapshot [--seed N] [--steps N] [--out path.png]
//                            [--width N] [--height N] [--organisms N]
//                            [--food N] [--food-every N]
//                            [--trail K] [--trail-every K]

struct CLI {
    var seed: UInt64 = 0xC0FFEE
    var steps: Int = 1800
    var width: Int = 720
    var height: Int = 720
    var initialOrganisms: Int = 24
    var foodPerSprinkle: Int = 8
    var foodEvery: Int = 180
    var trailFrames: Int = 0     // 0 = off
    var trailEvery: Int = 6      // capture every N ticks (so trail covers trailFrames * trailEvery ticks)
    var selectEvery: Int = 0     // 0 = off — tournament-selection cadence
    var keepFraction: Float = 0.4
    var out: String = "snapshot.png"

    static func parse(_ args: [String]) -> CLI {
        var c = CLI()
        var i = 1
        while i < args.count {
            let a = args[i]
            func nextVal() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            switch a {
            case "--seed":        if let v = nextVal(), let n = UInt64(v) { c.seed = n; i += 1 }
            case "--steps":       if let v = nextVal(), let n = Int(v) { c.steps = n; i += 1 }
            case "--width":       if let v = nextVal(), let n = Int(v) { c.width = n; i += 1 }
            case "--height":      if let v = nextVal(), let n = Int(v) { c.height = n; i += 1 }
            case "--organisms":   if let v = nextVal(), let n = Int(v) { c.initialOrganisms = n; i += 1 }
            case "--food":        if let v = nextVal(), let n = Int(v) { c.foodPerSprinkle = n; i += 1 }
            case "--food-every":  if let v = nextVal(), let n = Int(v) { c.foodEvery = n; i += 1 }
            case "--trail":       if let v = nextVal(), let n = Int(v) { c.trailFrames = n; i += 1 }
            case "--trail-every": if let v = nextVal(), let n = Int(v) { c.trailEvery = max(1, n); i += 1 }
            case "--select-every": if let v = nextVal(), let n = Int(v) { c.selectEvery = max(0, n); i += 1 }
            case "--keep":        if let v = nextVal(), let n = Float(v) { c.keepFraction = max(0.1, min(0.95, n)); i += 1 }
            case "--out":         if let v = nextVal() { c.out = v; i += 1 }
            case "-h", "--help":
                print("EvoSimSnapshot [--seed N] [--steps N] [--width W] [--height H] [--organisms N] [--food N] [--food-every N] [--trail K] [--trail-every K] [--out path.png]")
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown arg: \(a)\n".utf8))
            }
            i += 1
        }
        return c
    }
}

let cli = CLI.parse(CommandLine.arguments)

var world = World(seed: cli.seed)
world.seedRandomOrganisms(count: cli.initialOrganisms)
world.sprinkleFood(count: cli.foodPerSprinkle, amount: 220, sigma: 4.5)

print("[snapshot] seed=\(cli.seed) steps=\(cli.steps) organisms=\(world.colony.organismCount) cells=\(world.colony.count)")

// Ring buffer of (cellId, position) frames for trail rendering.
var trailFrames: [[(UInt32, SIMD3<Float>)]] = []

let t0 = Date()
for n in 0..<cli.steps {
    if cli.foodEvery > 0 && n > 0 && n % cli.foodEvery == 0 {
        world.sprinkleFood(count: cli.foodPerSprinkle, amount: 220, sigma: 4.5)
    }
    if cli.selectEvery > 0 && n > 0 && n % cli.selectEvery == 0 {
        let beforeOrg = world.colony.organismCount
        world.colony.applySelectionPressure(keepFraction: cli.keepFraction)
        if n % (cli.selectEvery * 4) == 0 {
            print("[snapshot] selection @ tick \(n): \(beforeOrg) → keep \(Int(Float(beforeOrg) * cli.keepFraction))")
        }
    }
    world.tick()
    if cli.trailFrames > 0 && n % cli.trailEvery == 0 {
        let frame = world.colony.cells.map { ($0.id, $0.position) }
        trailFrames.append(frame)
        if trailFrames.count > cli.trailFrames {
            trailFrames.removeFirst()
        }
    }
}
let wall = Date().timeIntervalSince(t0)
print(String(format: "[snapshot] %d steps in %.3fs (%.1f steps/s)  organisms=%d  cells=%d  bonds=%d  totalEnergy=%.2f",
             cli.steps, wall, Double(cli.steps) / wall,
             world.colony.organismCount, world.colony.count, world.colony.bonds.count, world.colony.totalEnergy_orZero))

var renderer = SnapshotRenderer(width: cli.width, height: cli.height)
renderer.trailFrames = trailFrames
let outURL = URL(fileURLWithPath: cli.out)
let ok = renderer.writePNG(world, to: outURL)
if !ok {
    FileHandle.standardError.write(Data("failed to write \(outURL.path)\n".utf8))
    exit(1)
}
print("[snapshot] wrote \(outURL.path) (\(cli.width)×\(cli.height))")

// MARK: - Quick helpers
extension Colony {
    var totalEnergy_orZero: Double {
        var s = 0.0
        for c in cells { s += Double(c.energy) }
        return s
    }
}
