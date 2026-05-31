import simd

/// A single cell. Genome and behavior arrive in Phase 2 — for now the cell is
/// the bare-minimum physical object: a position and an internal state vector.
/// State[0] is reserved as the "energy" channel that uptake feeds. All other
/// channels are uninterpreted: the NCA (Phase 2) will decide what they mean.
public struct Cell {
    /// Number of internal state channels. State[0] = energy by convention; all
    /// other channels are uninterpreted and become the NCA's working memory in
    /// Phase 2. Sized to a multiple of 4 to keep SIMD-friendly later.
    public static let stateChannelCount: Int = 16

    public var id: UInt32
    public var lineageId: UInt32
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var age: UInt32
    public var state: [Float]

    public init(
        id: UInt32,
        lineageId: UInt32,
        position: SIMD3<Float>,
        velocity: SIMD3<Float> = .zero
    ) {
        self.id = id
        self.lineageId = lineageId
        self.position = position
        self.velocity = velocity
        self.age = 0
        self.state = [Float](repeating: 0, count: Self.stateChannelCount)
    }

    @inlinable public var energy: Float {
        get { state[0] }
        set { state[0] = newValue }
    }
}

/// Container for all live cells in the world. Phase 1 just holds + ticks them;
/// Phase 2 will add division/death driven by the NCA.
public struct Colony {
    public private(set) var cells: [Cell]
    private var nextId: UInt32

    /// Uptake amount per cell per second from local nutrient grid.
    /// This is a physical property of the cell membrane, not an evolved trait
    /// (the NCA can later modulate it by writing to a designated state channel).
    public var uptakeRate: Float

    public init(uptakeRate: Float = 0.8) {
        self.cells = []
        self.nextId = 1
        self.uptakeRate = uptakeRate
    }

    @inlinable public var count: Int { cells.count }

    public mutating func spawn(at position: SIMD3<Float>, lineageId: UInt32) -> UInt32 {
        let id = nextId
        nextId &+= 1
        cells.append(Cell(id: id, lineageId: lineageId, position: position))
        return id
    }

    /// Phase 1 tick: each cell uptakes from its local chemistry grid cell.
    /// No movement, no division, no death — those require the genome (Phase 2).
    public mutating func tick(dt: Float, chemistry: inout NutrientField) {
        let perCell = uptakeRate * dt
        for n in 0..<cells.count {
            guard let g = chemistry.gridIndex(for: cells[n].position) else { continue }
            let taken = chemistry.uptake(at: g.i, g.j, g.k, amount: perCell)
            cells[n].energy += taken
            cells[n].age &+= 1
        }
    }
}
