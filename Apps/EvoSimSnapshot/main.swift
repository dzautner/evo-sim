import Foundation
import simd
import EvoSimCore
import EvoSimRender

// Tiny CLI: run the sim for N steps from a given seed, render a PNG.
// Usage:
//   swift run EvoSimSnapshot [--seed N] [--steps N] [--out path.png]
//                            [--width N] [--height N] [--cells N]
//                            [--food N]

struct CLI {
    var seed: UInt64 = 0xC0FFEE
    var steps: Int = 600
    var width: Int = 720
    var height: Int = 720
    var initialCells: Int = 1
    var foodDeposits: Int = 6
    var out: String = "snapshot.png"

    static func parse(_ args: [String]) -> CLI {
        var c = CLI()
        var i = 1
        while i < args.count {
            let a = args[i]
            func nextVal() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            switch a {
            case "--seed":   if let v = nextVal(), let n = UInt64(v) { c.seed = n; i += 1 }
            case "--steps":  if let v = nextVal(), let n = Int(v) { c.steps = n; i += 1 }
            case "--width":  if let v = nextVal(), let n = Int(v) { c.width = n; i += 1 }
            case "--height": if let v = nextVal(), let n = Int(v) { c.height = n; i += 1 }
            case "--cells":  if let v = nextVal(), let n = Int(v) { c.initialCells = n; i += 1 }
            case "--food":   if let v = nextVal(), let n = Int(v) { c.foodDeposits = n; i += 1 }
            case "--out":    if let v = nextVal() { c.out = v; i += 1 }
            case "-h", "--help":
                print("EvoSimSnapshot [--seed N] [--steps N] [--width W] [--height H] [--cells N] [--food N] [--out path.png]")
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

// Seed food: random Gaussian deposits scattered around the tank, plus one
// dense pocket near the cell so Phase 1 shows visible uptake.
let extent = SIMD3<Float>(
    Float(world.chemistry.nx) * world.chemistry.cellSize,
    Float(world.chemistry.ny) * world.chemistry.cellSize,
    Float(world.chemistry.nz) * world.chemistry.cellSize
)
let center = extent * 0.5
for _ in 0..<cli.foodDeposits {
    let p = SIMD3<Float>(
        Float(world.rng.nextUnit()) * extent.x,
        Float(world.rng.nextUnit()) * extent.y,
        Float(world.rng.nextUnit()) * extent.z
    )
    world.chemistry.deposit(at: p, amount: 220, sigma: 4.5)
}

// Seed cells near the middle. Phase 1 spawn is a stand-in for abiogenesis —
// once the NCA lands in Phase 2, divisions will populate the tank.
for n in 0..<cli.initialCells {
    let jitter = SIMD3<Float>(
        Float(world.rng.nextGaussian()) * 4,
        Float(world.rng.nextGaussian()) * 4,
        Float(world.rng.nextGaussian()) * 4
    )
    _ = world.colony.spawn(at: center + jitter, lineageId: UInt32(n + 1))
}

let startTotal = world.totalEnergy
print("[snapshot] seed=\(cli.seed) steps=\(cli.steps) cells=\(world.colony.count) totalEnergy=\(String(format: "%.4f", startTotal))")

let t0 = Date()
for _ in 0..<cli.steps { world.tick() }
let wall = Date().timeIntervalSince(t0)
let endTotal = world.totalEnergy
let drift = endTotal - startTotal
let driftPct = startTotal > 0 ? (drift / startTotal) * 100 : 0
print(String(format: "[snapshot] %d steps in %.3fs (%.1f steps/s)  totalEnergy=%.4f  drift=%.2e (%.4f%%)",
             cli.steps, wall, Double(cli.steps) / wall, endTotal, drift, driftPct))

let outURL = URL(fileURLWithPath: cli.out)
let renderer = SnapshotRenderer(width: cli.width, height: cli.height)
let ok = renderer.writePNG(world, to: outURL)
if !ok {
    FileHandle.standardError.write(Data("failed to write \(outURL.path)\n".utf8))
    exit(1)
}
print("[snapshot] wrote \(outURL.path) (\(cli.width)×\(cli.height))")
