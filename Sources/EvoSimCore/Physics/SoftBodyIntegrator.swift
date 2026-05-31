import simd

/// Semi-implicit Euler integrator for the cell mass-spring soft body.
/// Pure function of (positions, velocities, bonds, dt, bounds) → new
/// (positions, velocities, stress). Stress is the magnitude of net bond
/// force per cell, used as an NCA input on the next tick.
///
/// All cells have unit mass. Per-cell drag and boundary repulsion are
/// physical constants (medium viscosity, tank walls), not evolved traits.
public struct SoftBodyIntegrator {
    public var drag: Float = 1.8           // viscous medium
    public var boundaryStiffness: Float = 6.0
    public var maxVelocity: Float = 8.0    // clamp for stability
    public var breakStretchRatio: Float = 3.5

    public init() {}

    /// Returns (forces removed by bonds, indices of bonds that broke this tick).
    /// Mutates positions, velocities, and stress in place.
    public func integrate(
        positions: inout [SIMD3<Float>],
        velocities: inout [SIMD3<Float>],
        stress: inout [Float],
        bonds: inout [Bond],
        idIndex: [UInt32: Int],
        bounds: SIMD3<Float>,
        dt: Float
    ) {
        // Reset stress accumulator.
        for i in 0..<stress.count { stress[i] = 0 }

        var forces = [SIMD3<Float>](repeating: .zero, count: positions.count)

        // 1. Bond forces.
        var brokenIndices: [Int] = []
        for (bi, bond) in bonds.enumerated() {
            guard let ia = idIndex[bond.a], let ib = idIndex[bond.b] else {
                brokenIndices.append(bi); continue
            }
            let dp = positions[ia] - positions[ib]
            let dist = simd_length(dp)
            if dist > bond.restLength * breakStretchRatio {
                brokenIndices.append(bi); continue
            }
            if dist < 1e-5 {
                // Pathological overlap — give it a deterministic nudge so the
                // next tick has a defined direction.
                let nudge = SIMD3<Float>(1, 0, 0) * 0.001
                forces[ia] += nudge
                forces[ib] -= nudge
                continue
            }
            let dir = dp / dist
            let stretch = dist - bond.restLength
            let springF = -bond.stiffness * stretch * dir
            let relVel = velocities[ia] - velocities[ib]
            let dampF = -bond.damping * simd_dot(relVel, dir) * dir
            let f = springF + dampF
            forces[ia] += f
            forces[ib] -= f
            let mag = simd_length(f)
            stress[ia] += mag
            stress[ib] += mag
        }
        if !brokenIndices.isEmpty {
            var i = brokenIndices.count - 1
            while i >= 0 { bonds.remove(at: brokenIndices[i]); i -= 1 }
        }

        // 2. Per-cell drag + boundary repulsion + integration.
        for i in 0..<positions.count {
            var f = forces[i]
            f -= drag * velocities[i]

            // Soft wall repulsion: linear spring from each wall.
            let p = positions[i]
            if p.x < 0 { f.x += -boundaryStiffness * p.x }
            if p.x > bounds.x { f.x += -boundaryStiffness * (p.x - bounds.x) }
            if p.y < 0 { f.y += -boundaryStiffness * p.y }
            if p.y > bounds.y { f.y += -boundaryStiffness * (p.y - bounds.y) }
            if p.z < 0 { f.z += -boundaryStiffness * p.z }
            if p.z > bounds.z { f.z += -boundaryStiffness * (p.z - bounds.z) }

            // Semi-implicit Euler.
            var v = velocities[i] + f * dt
            // Velocity clamp keeps the sim from blowing up if a runaway
            // chain of bonds amplifies.
            let speed = simd_length(v)
            if speed > maxVelocity { v *= maxVelocity / speed }
            velocities[i] = v
            positions[i] = p + v * dt
        }

        // Normalise stress to a sane input range (tanh-friendly).
        for i in 0..<stress.count { stress[i] = tanhf(stress[i] * 0.2) }
    }
}
