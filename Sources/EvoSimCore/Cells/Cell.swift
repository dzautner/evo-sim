import simd

/// A single cell. Has a position, an internal state vector, and a reference
/// to its parent organism. The NCA in Genome reads the state vector + local
/// chemistry and produces all behaviour — there are no hardcoded body parts.
public struct Cell {
    /// Number of internal state channels. State[0] = energy by convention;
    /// the rest are uninterpreted working memory for the NCA.
    public static let stateChannelCount: Int = 16

    public var id: UInt32
    public var organismId: UInt32
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var age: UInt32
    public var state: [Float]

    public init(
        id: UInt32,
        organismId: UInt32,
        position: SIMD3<Float>,
        velocity: SIMD3<Float> = .zero,
        state: [Float]? = nil
    ) {
        self.id = id
        self.organismId = organismId
        self.position = position
        self.velocity = velocity
        self.age = 0
        self.state = state ?? [Float](repeating: 0, count: Self.stateChannelCount)
    }

    @inlinable public var energy: Float {
        get { state[0] }
        set { state[0] = newValue }
    }
}
