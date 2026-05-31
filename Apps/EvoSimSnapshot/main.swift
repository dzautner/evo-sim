import Foundation
import simd
import EvoSimCore
import EvoSimRender

// CLI: run the sim for N steps from a seed, write a PNG snapshot.
// Usage:
//   swift run EvoSimSnapshot [--seed N] [--steps N] [--out path.png]
//                            [--width N] [--height N] [--organisms N]
//                            [--food N] [--food-every N]

struct CLI {
    var seed: UInt64 = 0xC0FFEE
    var steps: Int = 1800
    var width: Int = 720
    var height: Int = 720
    var initialOrganisms: Int = 24
    var foodPerSprinkle: Int = 8
    var foodEvery: Int = 180   // ticks between sprinkles
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
            case "--out":         if let v = nextVal() { c.out = v; i += 1 }
            case "-h", "--help":
                print("EvoSimSnapshot [--seed N] [--steps N] [--width W] [--height H] [--organisms N] [--food N] [--food-every N] [--out path.png]")
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

// Initial seeding: K random organisms scattered across the tank + a starter
// pulse of food. From here on, evolution does its thing.
world.seedRandomOrganisms(count: cli.initialOrganisms)
world.sprinkleFood(count: cli.foodPerSprinkle, amount: 220, sigma: 4.5)

print("[snapshot] seed=\(cli.seed) steps=\(cli.steps) organisms=\(world.colony.organismCount) cells=\(world.colony.count)")

let t0 = Date()
for n in 0..<cli.steps {
    if cli.foodEvery > 0 && n > 0 && n % cli.foodEvery == 0 {
        world.sprinkleFood(count: cli.foodPerSprinkle, amount: 220, sigma: 4.5)
    }
    world.tick()
}
let wall = Date().timeIntervalSince(t0)
print(String(format: "[snapshot] %d steps in %.3fs (%.1f steps/s)  organisms=%d  cells=%d  totalEnergy=%.2f",
             cli.steps, wall, Double(cli.steps) / wall,
             world.colony.organismCount, world.colony.count, world.totalEnergy))

let renderer = SnapshotRenderer(width: cli.width, height: cli.height)
let outURL = URL(fileURLWithPath: cli.out)
let ok = renderer.writePNG(world, to: outURL)
if !ok {
    FileHandle.standardError.write(Data("failed to write \(outURL.path)\n".utf8))
    exit(1)
}
print("[snapshot] wrote \(outURL.path) (\(cli.width)×\(cli.height))")
