import simd

/// Semi-implicit Euler integrator for the cell mass-spring soft body.
/// Pure function of (positions, velocities, bonds, dt, bounds) → new
/// (positions, velocities, stress). Stress is the magnitude of net bond
/// force per cell, used as an NCA input on the next tick.
///
/// All cells have unit mass. Per-cell drag and boundary repulsion are
/// physical constants (medium viscosity, tank walls), not evolved traits.
public struct SoftBodyIntegrator {
    public var drag: Float = 0.9           // viscous medium (lower = creatures swim further per contraction)
    public var boundaryStiffness: Float = 6.0
    public var maxVelocity: Float = 8.0    // clamp for stability
    public var breakStretchRatio: Float = 3.5
    /// Max fractional contraction of a bond at full +1 contraction signal
    /// from both endpoints. Pushed higher than biology (myocytes ≈ 30%) so
    /// coordinated locomotion is reachable in tens of generations rather
    /// than thousands.
    public var maxContractionFraction: Float = 0.75

    public init() {}

    /// Mutates positions, velocities, and stress in place. `contraction` (per
    /// cell, range [-1, +1]) modulates each bond's effective rest length:
    ///     effL = restLength * (1 - maxContractionFraction * mean(cA, cB)+)
    /// Negative contraction (relaxation) is clamped to 0 — relaxed bonds use
    /// their nominal rest length, not a longer one.
    public func integrate(
        positions: inout [SIMD3<Float>],
        velocities: inout [SIMD3<Float>],
        stress: inout [Float],
        bonds: inout [Bond],
        idIndex: [UInt32: Int],
        contraction: [Float],
        externalForces: [SIMD3<Float>] = [],
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
            // Modulate rest length by the mean positive contraction of the
            // two endpoint cells. Cells with positive contraction signal
            // shorten the bonds they're part of → muscle.
            let cA = max(0, contraction[ia])
            let cB = max(0, contraction[ib])
            let contract = (cA + cB) * 0.5 * maxContractionFraction
            let effRest = bond.restLength * (1 - contract)
            let stretch = dist - effRest
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

        // 2. Per-cell drag + boundary repulsion + external + integration.
        let hasExtForces = externalForces.count == positions.count
        for i in 0..<positions.count {
            var f = forces[i]
            if hasExtForces { f += externalForces[i] }
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
