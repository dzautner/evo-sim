import SwiftUI
import Foundation
import simd
import EvoSimCore
import EvoSimRender

#if canImport(UIKit)
import UIKit
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

/// Cross-platform (macOS + iOS) live preview of the simulation. Owns the
/// simulation loop and re-bakes a SnapshotRenderer image at ~10 Hz onto the
/// background of a SwiftUI Canvas. Designed to drop straight into an iOS app
/// without modification — the same simulation core powers macOS and iPhone.
@MainActor
public final class TankViewModel: ObservableObject {
    @Published public private(set) var world: World
    @Published public var speedMultiplier: Double = 1.0
    @Published public var isPaused: Bool = false
    @Published public private(set) var bakedImage: CGImage?

    private var lastHostTime: CFTimeInterval = 0
    private var accumulator: Double = 0
    private var ticksSinceLastSprinkle: Int = 0
    private let maxStepsPerPump = 64
    private var timer: Timer?
    private var renderer: SnapshotRenderer

    public init(seed: UInt64 = 0xC0FFEE, initialOrganisms: Int = 24, renderResolution: Int = 512) {
        var w = World(seed: seed)
        w.seedRandomOrganisms(count: initialOrganisms)
        w.sprinkleFood(count: 12, amount: 220, sigma: 4.5)
        self.world = w
        self.renderer = SnapshotRenderer(width: renderResolution, height: renderResolution)
    }

    public func start() {
        lastHostTime = CACurrentMediaTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func reseed(seed: UInt64? = nil, organisms n: Int = 24) {
        let s = seed ?? UInt64.random(in: 1...UInt64.max)
        var w = World(seed: s)
        w.seedRandomOrganisms(count: n)
        w.sprinkleFood(count: 12, amount: 220, sigma: 4.5)
        world = w
    }

    public enum HandAction { case food, stir, pluck }

    public func handAction(_ action: HandAction, at p: CGPoint, in size: CGSize) {
        let extent = SIMD3<Float>(
            Float(world.chemistry.nx) * world.chemistry.cellSize,
            Float(world.chemistry.ny) * world.chemistry.cellSize,
            Float(world.chemistry.nz) * world.chemistry.cellSize
        )
        let fx = Float(p.x / size.width) * extent.x
        let fy = Float(p.y / size.height) * extent.y
        let centerPt = SIMD3<Float>(fx, fy, extent.z * 0.5)
        switch action {
        case .food:
            world.chemistry.deposit(at: centerPt, amount: 120, sigma: 3.5)
        case .stir:
            world.stirAt(centerPt, radius: 8, strength: 18)
        case .pluck:
            world.pluckNearest(centerPt, radius: 4)
        }
    }

    fileprivate func pump() {
        let now = CACurrentMediaTime()
        let dt = now - lastHostTime
        lastHostTime = now
        if !isPaused {
            accumulator += dt * speedMultiplier
            var stepped = 0
            while accumulator >= world.fixedDt && stepped < maxStepsPerPump {
                ticksSinceLastSprinkle += 1
                if ticksSinceLastSprinkle >= 240 {
                    world.sprinkleFood(count: 6)
                    ticksSinceLastSprinkle = 0
                }
                world.tick()
                accumulator -= world.fixedDt
                stepped += 1
            }
            if stepped == maxStepsPerPump { accumulator = 0 }
        }
        // Re-bake at ~10 Hz independent of sim speed.
        let pxBuf = renderer.renderRGBA(world)
        bakedImage = Self.makeImage(pixels: pxBuf, width: renderer.width, height: renderer.height)
    }

    private static func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info: CGBitmapInfo = [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs, bitmapInfo: info,
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

public struct TankView: View {
    @StateObject private var vm: TankViewModel

    public init(viewModel: TankViewModel? = nil) {
        _vm = StateObject(wrappedValue: viewModel ?? TankViewModel())
    }

    public var body: some View {
        VStack(spacing: 10) {
            tank
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(alignment: .topLeading) { hud.padding(12) }
                .overlay(alignment: .bottom) { hint.padding(.bottom, 10) }
            controls
        }
        .padding(12)
        .background(Color(white: 0.05))
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private var tank: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = vm.bakedImage {
                    Image(decorative: img, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                vm.handAction(.food, at: p, in: geo.size)
            }
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("step  \(vm.world.step)")
            Text(String(format: "t     %.2f s", vm.world.time))
            Text(String(format: "speed %.0fx", vm.speedMultiplier))
            Text("orgs  \(vm.world.colony.organismCount)")
            Text("cells \(vm.world.colony.count)")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.green.opacity(0.75))
    }

    private var hint: some View {
        Text("tap = drop food")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(vm.isPaused ? "▶︎ play" : "❚❚ pause") { vm.isPaused.toggle() }
            Button("⟳ reseed") { vm.reseed() }
            Spacer()
            ForEach([1.0, 10.0, 100.0], id: \.self) { mult in
                Button("\(Int(mult))x") { vm.speedMultiplier = mult }
                    .buttonStyle(.bordered)
                    .tint(vm.speedMultiplier == mult ? .green : .gray)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.green.opacity(0.9))
    }
}
