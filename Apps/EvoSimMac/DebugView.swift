import SwiftUI
import simd
import EvoSimCore
import EvoSimRender

/// Lightweight live preview. Re-renders via SnapshotRenderer at ~10 Hz
/// (decoupled from sim tick, which runs at 60 Hz). Sufficient for Phase 1
/// debugging; Phase 6 replaces this with Metal raymarching.
struct DebugView: View {
    @StateObject private var sim = Simulation()
    @State private var bakedImage: CGImage?
    @State private var bakeTimer: Timer?
    private let renderer = SnapshotRenderer(width: 512, height: 512)

    var body: some View {
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
        .onAppear {
            sim.start()
            bakeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { _ in
                Task { @MainActor in rebake() }
            }
        }
        .onDisappear {
            sim.stop()
            bakeTimer?.invalidate()
            bakeTimer = nil
        }
    }

    private var tank: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = bakedImage {
                    Image(decorative: img, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                sim.dropFoodAtScreenPoint(p, in: geo.size)
            }
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("step  \(sim.world.step)")
            Text(String(format: "t     %.2f s", sim.world.time))
            Text(String(format: "speed %.0fx", sim.speedMultiplier))
            Text("orgs  \(sim.world.colony.organismCount)")
            Text("cells \(sim.world.colony.count)")
            Text(String(format: "energy %.2f", sim.world.totalEnergy))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.green.opacity(0.75))
    }

    private var hint: some View {
        Text("click to drop food · Phase 2 of 6")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(sim.isPaused ? "▶︎ play" : "❚❚ pause") { sim.isPaused.toggle() }
            Spacer()
            ForEach([1.0, 10.0, 100.0], id: \.self) { mult in
                Button("\(Int(mult))x") { sim.speedMultiplier = mult }
                    .buttonStyle(.bordered)
                    .tint(sim.speedMultiplier == mult ? .green : .gray)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.green.opacity(0.9))
    }

    @MainActor
    private func rebake() {
        let pixels = renderer.renderRGBA(sim.world)
        bakedImage = makeImage(pixels: pixels, width: renderer.width, height: renderer.height)
    }

    private func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info: CGBitmapInfo = [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
