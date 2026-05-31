# evo-sim

Open-ended evolution sandbox. Single cells in a chemistry soup evolve into
multicellular creatures with truly emergent morphology. macOS dev target, iOS
later. Tamagotchi feel: user is a Black-&-White-style "hand" that drops food
and manipulates the environment.

## Hard design commitments

These are non-negotiable and override any "reasonable simplification":

1. **No body-part library, ever.** No code anywhere names "limb", "leg",
   "head", "eye", "mouth", or any anatomical part. Bodies are colonies of
   undifferentiated cells whose specializations emerge from the genome's
   developmental program. If a future change would introduce a body-part
   template, stop and ask.
2. **Genome = developmental program, not blueprint.** The genome encodes
   per-cell decision rules (divide / die / differentiate / contract / secrete).
   Macroscopic morphology is an emergent side-effect of these rules running in
   an environment. Two identical genomes in two different environments must be
   able to grow into noticeably different bodies.
3. **Selection acts on whole-organism viability only.** Fitness = survival +
   reproduction. Never reward intermediate features ("has a protrusion",
   "moves fast"). The environment does the selecting.
4. **Environment is a first-class morphogen.** Nutrient gradients, light,
   currents, mechanical stress, neighbor signals all feed into cell decisions.
   Cells must be able to read their local environment.
5. **Start from one cell in a chemistry soup.** Multicellularity itself has
   to evolve. Do not seed embryos.

## Architecture (locked)

- **Language/platform:** Swift, macOS first (fast iteration), iOS port later.
  Core simulation is a cross-platform Swift Package; apps are thin shells.
- **Genome:** Neural Cellular Automaton — each cell runs a small shared NN on
  `(own state vector, mean neighbor state, local chemistry, mechanical stress)`
  → outputs `(division signal, differentiation update, spring stiffness,
  contraction signal, secretion)`. Mutation = weight perturbation +
  occasional topology change. Whole organism shares one NN (one genome).
- **Physics:** 3D soft body. Cells are mass-points; bonds between
  recently-divided / nearby cells are damped springs whose rest length and
  stiffness are genome-controlled per-cell. Muscles = springs that contract on
  neural signal. Integrator: semi-implicit Euler at fixed timestep.
- **Chemistry:** 3D scalar fields on a coarse grid (nutrients, signaling
  molecules, oxygen-analog, waste). Diffusion + decay + cell uptake/secretion.
  Cells sample their grid cell.
- **Behavior:** Once motor/sensor cells exist (because the genome
  differentiated some cells into them), they wire into the same NCA — sensor
  cells inject environmental readings into their state vector, motor cells
  read a designated output channel to drive spring contraction.
- **Ecosystem:** Many creatures coexist in one tank. Reproduction is asexual
  with mutation (sexual later if it earns its place). Differential survival
  drives evolution.
- **Rendering:** Metal compute raymarching of an SDF metaball field over cell
  positions. One soft light, translucent medium, depth fog. Goal: pond-water-
  under-a-microscope vibe (Microcosmos, Panspermia). No meshes, no rigging —
  cell positions ARE the geometry.
- **Interaction:** Mouse/touch is the "hand". Drop food pellets, stir
  currents, pick up creatures, alter light. No god-button shortcuts that
  bypass the simulation.
- **Time:** Real-time playback with 1× / 10× / 100× speedup. A "life" is
  minutes; visible evolution over hours.

## Phased build plan

Each phase is independently shippable and visually verifiable.

- **Phase 0 — Scaffolding.** Swift Package layout, macOS app shell, debug
  2D top-down view (SwiftUI Canvas, no Metal yet), fixed-timestep sim loop.
- **Phase 1 — Chemistry + passive cell.** Nutrient field with diffusion +
  decay. Cell uptakes from local grid (membrane physics, not behavior). No
  division, no movement, no death — those wait for the NCA. Verify mass
  conservation (chemistry + cell energy) and stable diffusion. Snapshot CLI
  + PNG renderer for screenshots and CI.
- **Phase 2 — Morphogenesis (NCA genome).** Introduce per-organism NCA
  network. NCA reads (own state, mean neighbor state, local chemistry,
  mechanical stress); outputs decide division / death / state update /
  spring stiffness / contraction / secretion. Mutation + asexual
  reproduction. Verify: two different random genomes grow visibly different
  bodies in the same chemistry environment.
- **Phase 3 — Soft-body physics.** Spring mesh between cells, semi-implicit
  Euler. Genome controls spring stiffness. Verify: bodies deform under
  gravity / currents, don't explode.
- **Phase 4 — Behavior.** Sensor + motor cell types (still emergent from
  genome — just additional output channels). Verify: some lineage discovers
  directed motion toward food in <24h of sim time on one tank.
- **Phase 5 — Ecosystem.** Many creatures, predation (cell-on-cell), open
  world boundaries, hand interaction.
- **Phase 6 — Cross-platform polish.** EvoSimAppKit module: a shared
  SwiftUI `TankView` + `TankViewModel` that runs on both macOS and iOS.
  Renderer gets z-depth shading (front cells brighter/larger), vignette,
  per-cell role coloring (red = predator, orange = motor, green =
  structural), and red predation-event arcs so feeding is visible. Metal
  SDF raymarching is deferred — current CPU renderer achieves the
  "rough ray tracing / microscope" aesthetic the user asked for, at >250
  steps/s on 2500 cells. Drop in Metal later when more visual fidelity is
  needed.

Do not start a phase until the prior phase has a green visual verification.

## Conventions

- **Source layout:** `Sources/EvoSimCore/` (sim engine, platform-agnostic,
  no UI imports), `Sources/EvoSimRender/` (Metal shaders + render pipeline),
  `Apps/EvoSimMac/`, later `Apps/EvoSimIOS/`. Tests under `Tests/`.
- **Determinism:** sim is deterministic given (seed, genome, initial
  conditions). All RNG goes through an injected `RandomSource`. Never call
  `Double.random()` or `Int.random()` directly inside the sim.
- **No Foundation in the hot loop.** Sim core uses `simd_*` types, plain
  arrays, no `Date`, no `String` allocations per step.
- **Profiling-first.** Every sim subsystem has a microbenchmark in
  `Tests/Bench/`. Target: 10k cells at 60 Hz on M-series.
- **Visual verification is the test.** For sim behavior, prefer a recorded
  short visual clip + assertion on summary stats over unit tests on
  intermediate state. Cell-level state is not API.

## The "law of nature" vs "evolved trait" boundary

Some things are physics — present in every cell, never up for evolution to
discover. Others are morphology / behavior — the genome decides. Keep them
sharply separate:

- **Laws of nature (given):** chemistry diffusion + decay, mass
  conservation, soft-body spring physics, membrane uptake of nutrient from
  the local grid cell, gravity / currents / boundary conditions. The cell's
  **energy reservoir (state channel 0)** is physics — modified only by
  uptake, metabolic cost, and division share. The NCA's Δstate output for
  channel 0 is discarded so evolution can't conjure energy from nothing.
- **Evolved (genome-driven):** when to divide, when to die, where to push
  daughter cell, what to differentiate into, what to secrete, spring
  stiffness / rest length per bond, motor contraction signals, any sensor
  weighting. Nothing in this list may be hardcoded — even as a placeholder.

If a feature is on the "evolved" side, it lands in the codebase ONLY
through the NCA's outputs. No `if energy > X { divide() }` shortcuts, even
"just to test."

## Anti-patterns (will be rejected on sight)

- Hardcoded body parts or "creature classes".
- Direct fitness rewards for intermediate traits.
- Per-cell `Foundation` allocations in the sim loop.
- Non-deterministic RNG inside the sim.
- Render code reaching into sim mutable state.
- A "make it cool" shortcut that skips the simulation (e.g. procedurally
  generating creature shapes for the demo).
