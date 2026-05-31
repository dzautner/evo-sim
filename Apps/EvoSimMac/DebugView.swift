import SwiftUI
import EvoSimCore

struct DebugView: View {
    @StateObject private var sim = Simulation()

    var body: some View {
        VStack(spacing: 10) {
            tank
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(alignment: .topLeading) { hud.padding(12) }
            controls
        }
        .padding(12)
        .background(Color(white: 0.05))
        .onAppear { sim.start() }
        .onDisappear { sim.stop() }
    }

    private var tank: some View {
        Canvas { context, size in
            let inset: CGFloat = 6
            let rect = CGRect(
                x: inset, y: inset,
                width: size.width - 2 * inset,
                height: size.height - 2 * inset
            )
            context.stroke(
                Path(rect),
                with: .color(.green.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("step  \(sim.world.step)")
            Text(String(format: "t     %.2f s", sim.world.time))
            Text(String(format: "speed %.0fx", sim.speedMultiplier))
            Text("cells 0   (Phase 1)")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.green.opacity(0.75))
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
}
