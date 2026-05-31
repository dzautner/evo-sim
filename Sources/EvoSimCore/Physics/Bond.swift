import simd

/// A mass-spring bond between two cells, created on division and broken if
/// the cells drift too far apart. Genome controls per-bond stiffness at
/// creation (see Colony.applyDivision). Damping is fixed — it's a property
/// of the surrounding medium, not an evolved trait.
public struct Bond {
    public var a: UInt32          // cell id A
    public var b: UInt32          // cell id B
    public var restLength: Float
    public var stiffness: Float
    public var damping: Float

    public init(a: UInt32, b: UInt32, restLength: Float, stiffness: Float, damping: Float = 0.6) {
        self.a = a
        self.b = b
        self.restLength = restLength
        self.stiffness = stiffness
        self.damping = damping
    }
}
