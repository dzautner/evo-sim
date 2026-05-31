import simd

/// One organism = one genome + a unique id. All cells with that organismId
/// share this genome (and its NCA workspace) for forward passes.
public struct Organism {
    public var id: UInt32
    public var genome: Genome
    public var workspace: NCA.Workspace
    public var ageTicks: UInt64

    public init(id: UInt32, genome: Genome) {
        self.id = id
        self.genome = genome
        self.workspace = NCA.Workspace(shape: genome.shape)
        self.ageTicks = 0
    }
}

/// All cells in the world, plus their parent organisms. Tick runs the NCA
/// for every cell, applies its outputs (Δstate, divide, bud, die, direction),
/// and handles deaths / new-organism budding. No hardcoded biology lives here
/// — everything except uptake (membrane physics) is gated on NCA outputs.
public struct Colony {
    public private(set) var cells: [Cell]
    public private(set) var organisms: [UInt32: Organism]
    public private(set) var nextCellId: UInt32 = 1
    public private(set) var nextOrganismId: UInt32 = 1

    // Tunables — these are physics / metabolic constants, not evolved traits.
    public var uptakeRate: Float = 1.2           // nutrient → energy per second
    public var metabolicCost: Float = 0.035      // energy spent per second just to live
    public var divisionEnergyCost: Float = 0.5   // parent pays this on divide
    public var minDivideEnergy: Float = 1.0      // can't divide if energy below
    public var maxCells: Int = 6000              // tank hard cap
    public var stateStep: Float = 0.25           // Δstate applied as: s += step * Δ
    public var neighborRadius: Float = 2.2       // for mean-neighbor input
    public var budSpacing: Float = 1.5           // daughter cell offset on divide
    public var mutationRate: Float = 0.07
    public var mutationSigma: Float = 0.10
    public var macroMutationRate: Float = 0.004
    public var macroMutationSigma: Float = 0.7

    // Decision thresholds on NCA outputs (post-tanh, range -1..1).
    // Liberal divide/bud thresholds so random init produces enough behaviour
    // for selection to act on. Death stays conservative so accidental
    // self-extinction is rare.
    public var divideThreshold: Float = 0.0
    public var budThreshold: Float = 0.35
    public var dieThreshold: Float = 0.85

    // Per-cell scratch buffers — sized for current genome shape.
    private var inputBuf: [Float] = []
    private var outputBuf: [Float] = []
    private var lastGenomeShape: GenomeShape?

    public init() {
        self.cells = []
        self.organisms = [:]
    }

    @inlinable public var count: Int { cells.count }
    @inlinable public var organismCount: Int { organisms.count }

    public mutating func registerOrganism(genome: Genome) -> UInt32 {
        let oid = nextOrganismId; nextOrganismId &+= 1
        organisms[oid] = Organism(id: oid, genome: genome)
        return oid
    }

    @discardableResult
    public mutating func spawn(at position: SIMD3<Float>, organismId: UInt32, initialEnergy: Float = 0.6) -> UInt32 {
        let id = nextCellId; nextCellId &+= 1
        var c = Cell(id: id, organismId: organismId, position: position)
        c.energy = initialEnergy
        cells.append(c)
        return id
    }

    /// Main per-tick step. Order:
    ///   1. Rebuild spatial index.
    ///   2. For each cell: compute NCA input from local state, gather
    ///      neighbours' mean state, sample chemistry + gradient, forward
    ///      pass, apply Δstate, decide divide / bud / die.
    ///   3. Uptake from chemistry, subtract metabolic cost.
    ///   4. Apply pending births and deaths.
    public mutating func tick(
        dt: Float,
        chemistry: inout NutrientField,
        index: inout SpatialIndex,
        rng: inout Xoshiro256
    ) {
        guard !cells.isEmpty, !organisms.isEmpty else { return }

        let stateCh = Cell.stateChannelCount
        let inSize = NCAInput.size(stateChannels: stateCh)
        let outSize = NCAOutput.size(stateChannels: stateCh)
        let shape = organisms.values.first!.genome.shape
        if lastGenomeShape != shape {
            inputBuf = [Float](repeating: 0, count: inSize)
            outputBuf = [Float](repeating: 0, count: outSize)
            lastGenomeShape = shape
        }
        precondition(shape.inputSize == inSize && shape.outputSize == outSize,
                     "genome shape doesn't match cell state layout")

        // 1. Rebuild spatial index.
        let positions = cells.map { $0.position }
        index.rebuild(positions: positions)

        // Pending mutations to apply after the read pass (don't mutate cells
        // we're iterating).
        struct PendingBirth { var organismId: UInt32; var position: SIMD3<Float>; var inheritedState: [Float] }
        struct PendingMutBirth { var parentOrganismId: UInt32; var position: SIMD3<Float>; var inheritedState: [Float] }
        var newCells: [PendingBirth] = []
        var newBuds: [PendingMutBirth] = []
        var deaths = Set<Int>()
        var newStates: [[Float]] = Array(repeating: [], count: cells.count)
        var energyAfterMetab: [Float] = Array(repeating: 0, count: cells.count)

        let r2 = neighborRadius * neighborRadius

        // 2. NCA forward per cell.
        for ci in 0..<cells.count {
            let cell = cells[ci]
            guard let org = organisms[cell.organismId] else { deaths.insert(ci); continue }

            // Mean neighbor state.
            var meanNeighbor = [Float](repeating: 0, count: stateCh)
            var neighborCount: Float = 0
            index.forEachNeighbor(of: cell.position, radius: neighborRadius) { nj in
                if nj == ci { return }
                let dp = cells[nj].position - cell.position
                let d2 = simd_dot(dp, dp)
                if d2 <= r2 {
                    for k in 0..<stateCh { meanNeighbor[k] += cells[nj].state[k] }
                    neighborCount += 1
                }
            }
            if neighborCount > 0 {
                let inv = 1.0 / neighborCount
                for k in 0..<stateCh { meanNeighbor[k] *= inv }
            }

            // Chemistry: local concentration + central-difference gradient.
            let (cAt, gradX, gradY, gradZ) = sampleChemistryAt(cell.position, in: chemistry)

            // Assemble input vector.
            // Layout: [own state | mean neighbor state | c, gx, gy, gz | stress, bias]
            for k in 0..<stateCh { inputBuf[k] = cell.state[k] }
            for k in 0..<stateCh { inputBuf[stateCh + k] = meanNeighbor[k] }
            inputBuf[2 * stateCh + 0] = cAt
            inputBuf[2 * stateCh + 1] = gradX
            inputBuf[2 * stateCh + 2] = gradY
            inputBuf[2 * stateCh + 3] = gradZ
            inputBuf[2 * stateCh + 4] = 0  // stress placeholder (Phase 3)
            inputBuf[2 * stateCh + 5] = 1  // bias

            // Forward pass uses organism's workspace.
            var ws = org.workspace
            NCA.forward(genome: org.genome, input: inputBuf, output: &outputBuf, workspace: &ws)
            organisms[cell.organismId]?.workspace = ws

            // 2a. Δstate (scaled). Channel 0 = energy and is governed strictly
            // by physics (uptake + metabolic cost + division share). The NCA
            // cannot write to it — otherwise evolution learns the trivial
            // "wish more energy into existence" exploit, conserving nothing.
            var newState = cell.state
            for k in 1..<stateCh {
                newState[k] = clamp(newState[k] + stateStep * outputBuf[k], lo: -2, hi: 2)
            }
            newStates[ci] = newState

            // 2b. Metabolic cost (physics, not evolved).
            let postMetab = newState[0] - metabolicCost * dt
            energyAfterMetab[ci] = postMetab

            // 2c. Decide divide / bud / die from signals (tanh ⇒ -1..1).
            let divideSig = outputBuf[stateCh + NCAOutput.divideIdx]
            let budSig    = outputBuf[stateCh + NCAOutput.budIdx]
            let dieSig    = outputBuf[stateCh + NCAOutput.dieIdx]

            if dieSig > dieThreshold { deaths.insert(ci); continue }
            if postMetab <= 0 { deaths.insert(ci); continue }

            if divideSig > divideThreshold,
               postMetab >= minDivideEnergy,
               cells.count + newCells.count + newBuds.count < maxCells {
                let dir = SIMD3<Float>(
                    outputBuf[stateCh + NCAOutput.divDirIdx + 0],
                    outputBuf[stateCh + NCAOutput.divDirIdx + 1],
                    outputBuf[stateCh + NCAOutput.divDirIdx + 2]
                )
                var ndir = dir
                let dl = simd_length(ndir)
                if dl < 1e-3 {
                    ndir = SIMD3<Float>(
                        Float(rng.nextGaussian()),
                        Float(rng.nextGaussian()),
                        Float(rng.nextGaussian())
                    )
                    let l2 = simd_length(ndir)
                    ndir = l2 > 1e-3 ? ndir / l2 : SIMD3<Float>(1, 0, 0)
                } else {
                    ndir /= dl
                }
                let daughterPos = cell.position + ndir * budSpacing

                // Parent pays the energy cost and shares remaining energy with daughter.
                let afterCost = postMetab - divisionEnergyCost
                let parentShare = max(0.05, afterCost * 0.55)
                let daughterShare = max(0.05, afterCost * 0.45)
                energyAfterMetab[ci] = parentShare

                // Daughter inherits parent's full state, with its own energy slot.
                var daughterState = newState
                daughterState[0] = daughterShare

                if budSig > budThreshold {
                    newBuds.append(PendingMutBirth(
                        parentOrganismId: cell.organismId,
                        position: daughterPos,
                        inheritedState: daughterState
                    ))
                } else {
                    newCells.append(PendingBirth(
                        organismId: cell.organismId,
                        position: daughterPos,
                        inheritedState: daughterState
                    ))
                }
            }
        }

        // 3. Uptake (membrane physics) and write back states + energy.
        let perCellUptake = uptakeRate * dt
        for ci in 0..<cells.count {
            if deaths.contains(ci) { continue }
            // Apply Δstate.
            cells[ci].state = newStates[ci]
            // Uptake from local chemistry into energy.
            if let g = chemistry.gridIndex(for: cells[ci].position) {
                let taken = chemistry.uptake(at: g.i, g.j, g.k, amount: perCellUptake)
                cells[ci].energy = energyAfterMetab[ci] + taken
            } else {
                cells[ci].energy = energyAfterMetab[ci]
            }
            cells[ci].age &+= 1
        }

        // 4. Apply births.
        for b in newCells {
            spawn(at: b.position, organismId: b.organismId, initialEnergy: b.inheritedState[0])
            cells[cells.count - 1].state = b.inheritedState
        }
        for b in newBuds {
            guard let parent = organisms[b.parentOrganismId] else { continue }
            let mutated = parent.genome.mutated(
                rate: mutationRate, sigma: mutationSigma,
                macroRate: macroMutationRate, macroSigma: macroMutationSigma,
                rng: &rng
            )
            let oid = registerOrganism(genome: mutated)
            spawn(at: b.position, organismId: oid, initialEnergy: b.inheritedState[0])
            cells[cells.count - 1].state = b.inheritedState
        }

        // 5. Age organisms; prune dead cells; drop organisms with no cells.
        for (oid, var o) in organisms {
            o.ageTicks &+= 1
            organisms[oid] = o
        }
        if !deaths.isEmpty {
            var kept: [Cell] = []
            kept.reserveCapacity(cells.count - deaths.count)
            for (i, c) in cells.enumerated() where !deaths.contains(i) { kept.append(c) }
            cells = kept
        }
        var liveOrgs = Set<UInt32>()
        for c in cells { liveOrgs.insert(c.organismId) }
        for oid in organisms.keys where !liveOrgs.contains(oid) {
            organisms.removeValue(forKey: oid)
        }
    }

    // MARK: - Helpers

    /// Returns (concentration, ∂c/∂x, ∂c/∂y, ∂c/∂z) at a world-space position
    /// using central differences on the underlying grid.
    @inline(__always)
    private func sampleChemistryAt(_ p: SIMD3<Float>, in cf: NutrientField) -> (Float, Float, Float, Float) {
        guard let g = cf.gridIndex(for: p) else { return (0, 0, 0, 0) }
        let c = cf.sample(at: g.i, g.j, g.k)
        let dx = (cf.sample(at: g.i + 1, g.j, g.k) - cf.sample(at: g.i - 1, g.j, g.k)) * 0.5
        let dy = (cf.sample(at: g.i, g.j + 1, g.k) - cf.sample(at: g.i, g.j - 1, g.k)) * 0.5
        let dz = (cf.sample(at: g.i, g.j, g.k + 1) - cf.sample(at: g.i, g.j, g.k - 1)) * 0.5
        return (c, dx, dy, dz)
    }

    @inline(__always)
    private func clamp(_ v: Float, lo: Float, hi: Float) -> Float {
        min(hi, max(lo, v))
    }
}
