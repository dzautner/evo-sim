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
    public private(set) var bonds: [Bond] = []
    /// Parallel to `cells`: velocity used by the soft-body integrator.
    public private(set) var velocities: [SIMD3<Float>] = []
    /// Parallel to `cells`: normalised mechanical stress (|net bond force|),
    /// fed back to the NCA on the next tick as a proprioceptive input.
    public private(set) var stress: [Float] = []
    /// Parallel to `cells`: contraction signal from this cell's last NCA
    /// forward pass. Bonds shorten as a function of their endpoints'
    /// contraction. The NCA chooses how / when to contract — locomotion has
    /// to be discovered.
    public private(set) var contraction: [Float] = []
    /// Parallel to `cells`: predation signal from last NCA forward pass.
    /// When positive and a different-organism cell is within attack range,
    /// the predator drains energy on contact. Cell becomes a "mouth" only
    /// if its lineage discovers that this output is useful.
    public private(set) var predation: [Float] = []

    /// Recent predation events (predator pos, prey pos, age in ticks). Ages
    /// tick down each frame; events drop off after `predationEventLifetime`.
    /// Renderer uses this to flash red arcs between hunter and prey so eating
    /// is visible.
    public struct PredationEvent {
        public var predator: SIMD3<Float>
        public var prey: SIMD3<Float>
        public var amount: Float
        public var age: Int
    }
    public private(set) var recentPredations: [PredationEvent] = []
    public var predationEventLifetime: Int = 12
    public private(set) var nextCellId: UInt32 = 1
    public private(set) var nextOrganismId: UInt32 = 1

    public var integrator: SoftBodyIntegrator = SoftBodyIntegrator()

    // Tunables — these are physics / metabolic constants, not evolved traits.
    public var uptakeRate: Float = 1.2           // nutrient → energy per second
    public var metabolicCost: Float = 0.035      // energy spent per second just to live
    public var divisionEnergyCost: Float = 0.5   // parent pays this on divide
    public var minDivideEnergy: Float = 1.0      // can't divide if energy below
    public var maxCells: Int = 2500              // tank hard cap (perf bound)
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

    /// Hand-action helper: nudge a cell's velocity directly.
    public mutating func applyImpulse(at i: Int, impulse: SIMD3<Float>) {
        guard i >= 0, i < velocities.count else { return }
        velocities[i] += impulse
    }

    /// Hand-action helper: mark a cell to die at the next tick by zeroing
    /// its energy. Bonds clean up automatically in the death pass.
    public mutating func killCell(atIndex i: Int) {
        guard i >= 0, i < cells.count else { return }
        cells[i].energy = -1  // negative → metabolism check kills it next tick
    }

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
        velocities.append(.zero)
        stress.append(0)
        contraction.append(0)
        predation.append(0)
        return id
    }

    /// Main per-tick step. Order:
    ///   1. Rebuild spatial index from current positions.
    ///   2. For each cell: NCA forward (input includes last-tick stress),
    ///      decide Δstate / divide / bud / die, queue births.
    ///   3. Apply Δstate, uptake, metabolism.
    ///   4. Apply births (new cells + parent-daughter bonds).
    ///   5. Prune dead cells and bonds.
    ///   6. Soft-body integrator: spring + drag + boundary; updates stress.
    public mutating func tick(
        dt: Float,
        chemistry: inout NutrientField,
        index: inout SpatialIndex,
        bounds: SIMD3<Float>,
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
        struct PendingBirth {
            var organismId: UInt32
            var parentId: UInt32     // for bond creation
            var position: SIMD3<Float>
            var inheritedState: [Float]
            var bondStiffness: Float // from parent's NCA output at division time
        }
        struct PendingMutBirth {
            var parentOrganismId: UInt32
            var position: SIMD3<Float>
            var inheritedState: [Float]
        }
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
            inputBuf[2 * stateCh + 4] = stress[ci]  // mechanical stress from prev tick
            inputBuf[2 * stateCh + 5] = 1           // bias

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

            // 2d. Latch contraction + predation signals so the integrator and
            //     predation pass can use them this tick. tanh output [-1, 1].
            contraction[ci] = outputBuf[stateCh + NCAOutput.contractionIdx]
            predation[ci]   = outputBuf[stateCh + NCAOutput.predationIdx]

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
                    // Budding → new organism, no physical bond to parent.
                    newBuds.append(PendingMutBirth(
                        parentOrganismId: cell.organismId,
                        position: daughterPos,
                        inheritedState: daughterState
                    ))
                } else {
                    // Same-organism division → physical bond inherits the
                    // parent's bondStiffness output (mapped to [0.3, 2.7]).
                    let stiffSig = outputBuf[stateCh + NCAOutput.bondStiffnessIdx]
                    let stiffness = 1.5 + stiffSig * 1.2
                    newCells.append(PendingBirth(
                        organismId: cell.organismId,
                        parentId: cell.id,
                        position: daughterPos,
                        inheritedState: daughterState,
                        bondStiffness: stiffness
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

        // 4. Apply births (same-organism divisions → parent-daughter bond;
        //    buds → new organism with mutated genome, no physical bond).
        for b in newCells {
            let daughterId = spawn(at: b.position, organismId: b.organismId, initialEnergy: b.inheritedState[0])
            cells[cells.count - 1].state = b.inheritedState
            bonds.append(Bond(
                a: b.parentId,
                b: daughterId,
                restLength: budSpacing,
                stiffness: b.bondStiffness
            ))
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

        // 5. Age organisms; prune dead cells + their parallel arrays; drop
        //    organisms with no cells; drop bonds touching removed cells.
        for (oid, var o) in organisms {
            o.ageTicks &+= 1
            organisms[oid] = o
        }
        if !deaths.isEmpty {
            var keptCells: [Cell] = []
            var keptVel: [SIMD3<Float>] = []
            var keptStress: [Float] = []
            var keptContraction: [Float] = []
            var keptPredation: [Float] = []
            let kept = cells.count - deaths.count
            keptCells.reserveCapacity(kept)
            keptVel.reserveCapacity(kept)
            keptStress.reserveCapacity(kept)
            keptContraction.reserveCapacity(kept)
            keptPredation.reserveCapacity(kept)
            var deadIds = Set<UInt32>()
            for i in 0..<cells.count {
                if deaths.contains(i) {
                    deadIds.insert(cells[i].id)
                } else {
                    keptCells.append(cells[i])
                    keptVel.append(velocities[i])
                    keptStress.append(stress[i])
                    keptContraction.append(contraction[i])
                    keptPredation.append(predation[i])
                }
            }
            cells = keptCells
            velocities = keptVel
            stress = keptStress
            contraction = keptContraction
            predation = keptPredation
            if !deadIds.isEmpty {
                bonds.removeAll { deadIds.contains($0.a) || deadIds.contains($0.b) }
            }
        }
        var liveOrgs = Set<UInt32>()
        for c in cells { liveOrgs.insert(c.organismId) }
        for oid in organisms.keys where !liveOrgs.contains(oid) {
            organisms.removeValue(forKey: oid)
        }

        // 6. Inter-organism interactions: repulsion (no-overlap between
        //    different-organism cells) + predation energy drain.
        var externalForces = [SIMD3<Float>](repeating: .zero, count: cells.count)
        if cells.count > 1 {
            // Rebuild index using up-to-date positions (births/deaths happened).
            let positions = cells.map { $0.position }
            index.rebuild(positions: positions)

            let repulsionRadius: Float = cellHardRadius * 2
            let r2 = repulsionRadius * repulsionRadius
            let attackRadius: Float = cellHardRadius * 2.4
            let attack2 = attackRadius * attackRadius

            for i in 0..<cells.count {
                let ci = cells[i]
                let pi = ci.position
                let oid = ci.organismId
                index.forEachNeighbor(of: pi, radius: max(repulsionRadius, attackRadius)) { nj in
                    if nj <= i { return }
                    let cj = cells[nj]
                    if cj.organismId == oid { return }  // same organism handled by bonds
                    let dp = cells[nj].position - pi
                    let d2 = simd_dot(dp, dp)
                    if d2 > attack2 { return }
                    let d = d2.squareRoot()
                    let dir: SIMD3<Float>
                    if d > 1e-4 {
                        dir = dp / d
                    } else {
                        dir = SIMD3<Float>(
                            Float(rng.nextGaussian()),
                            Float(rng.nextGaussian()),
                            Float(rng.nextGaussian())
                        )
                    }

                    // Repulsion: linear spring inside the hard-overlap zone.
                    if d2 < r2 {
                        let depth = (repulsionRadius - d)
                        let f = repulsionStiffness * depth * dir
                        externalForces[i] -= f
                        externalForces[nj] += f
                    }

                    // Predation: closer than attackRadius and at least one
                    // side is signalling. Drain proportional to attack signal
                    // × dt; predator gains a fraction (conversion efficiency).
                    let aI  = max(0, predation[i])
                    let aNJ = max(0, predation[nj])
                    if aI > 0.2 && cells[nj].energy > 0 {
                        let drain = predationRate * aI * dt
                        let taken = min(drain, cells[nj].energy)
                        cells[nj].energy -= taken
                        cells[i].energy  += taken * predationEfficiency
                        externalForces[nj] += dir * predationPush * aI
                        if taken > 0.005 {
                            recentPredations.append(PredationEvent(
                                predator: cells[i].position,
                                prey: cells[nj].position,
                                amount: taken, age: 0
                            ))
                        }
                    }
                    if aNJ > 0.2 && cells[i].energy > 0 {
                        let drain = predationRate * aNJ * dt
                        let taken = min(drain, cells[i].energy)
                        cells[i].energy  -= taken
                        cells[nj].energy += taken * predationEfficiency
                        externalForces[i] -= dir * predationPush * aNJ
                        if taken > 0.005 {
                            recentPredations.append(PredationEvent(
                                predator: cells[nj].position,
                                prey: cells[i].position,
                                amount: taken, age: 0
                            ))
                        }
                    }
                }
            }
            // Age + cull predation events.
            for n in 0..<recentPredations.count { recentPredations[n].age += 1 }
            recentPredations.removeAll { $0.age > predationEventLifetime }
        } else {
            recentPredations.removeAll(keepingCapacity: true)
        }

        // 7. Soft-body physics.
        if !cells.isEmpty {
            var positions = cells.map { $0.position }
            var idIndex: [UInt32: Int] = [:]
            idIndex.reserveCapacity(cells.count)
            for (i, c) in cells.enumerated() { idIndex[c.id] = i }
            integrator.integrate(
                positions: &positions,
                velocities: &velocities,
                stress: &stress,
                bonds: &bonds,
                idIndex: idIndex,
                contraction: contraction,
                externalForces: externalForces,
                bounds: bounds,
                dt: dt
            )
            for i in 0..<cells.count { cells[i].position = positions[i] }
        }
    }

    // MARK: - Inter-organism tunables (physics, not evolved)
    public var cellHardRadius: Float = 0.6
    public var repulsionStiffness: Float = 4.0
    public var predationRate: Float = 1.6
    public var predationEfficiency: Float = 0.7
    public var predationPush: Float = 1.2

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
