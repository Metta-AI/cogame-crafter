# What this is, and is not, a port of

`cogame-crafter` implements the **problem** posed by Crafter (Hafner 2021) and
Craftax (Matthews et al. 2024). **It does not port either.** No upstream code
is vendored, no upstream number is claimed as reproduced, and **no score from
this coworld is comparable to a published Crafter or Craftax figure.**

What *is* reproduced is the shape of the problem: a 64 × 64 procedurally
generated world seen nine cells at a time, day and night, four vitals, the same
**seventeen actions by name**, and the same **twenty-two achievements by name
and in the same order**.

Every divergence is enumerated here.

---

## 1. No `crafter` and no `craftax` dependency, and no bit-exactness with either

Decided as a scoping rail before design. Crafter is Python (numpy, OpenSimplex,
an `imageio` renderer); Craftax is JAX. Embedding either means a simulator that
cannot compile to WebAssembly, and the **static wasm replay viewer is a
non-optional platform pin** — every hosted replay is served from
`/v2/coworlds/replays/static/<cow_id>/<sha>/index.html`, which loads the sim
itself in the browser. So the sim is Nim, it compiles twice (natively into
`/bin/crafter` and to wasm through `replay-viewer/config.nims`), and it is this
repo's own rules.

## 2. Integer value noise, not OpenSimplex

The generator is a hashed lattice of stride 8 whose corner values are
`mix64(seed, fieldSalt, gx, gy) mod 1024`, bilinearly interpolated in 16-bit
**fixed point**. A float noise field cannot be hashed identically native and in
wasm, and the per-tick `gameHash` chain the viewer re-checks is what makes a
replay verifiable at all.

The resulting worlds are recognisably the same *kind* of world — grass plains,
water, sand shores, forests, a mountain massif with cave floor, lava and ores
at depth — and they are **not** the same worlds.

## 3. Episode length

Crafter allows 10 000 steps. This game allows **1344** (56 turns × 24 ticks),
because the seat is an LLM on a 720 s budget. The vitals drain rates
(40 / 30 / 50), the day length (192) and the ore depths are all scaled to that
budget so the tech tree is genuinely completable.

## 4. Actions are batched under a driver, not stepped one per call

The "per-tick discrete" interface is preserved exactly as the seventeen
primitives; what changed is *who calls it*. Up to twenty-four primitives per
LLM turn under a deterministic driver, plus two macros (`goto`, `move`) and an
`n` multiplier on `do` / `sleep`. One LLM call per primitive would be 1344
calls inside a 720 s budget — impossible — and a policy that cannot express
"walk over there" spends every turn walking.

The **flinch rule** is what keeps batching from removing reactivity: any damage
from a creature, an arrow or lava ends the turn on the spot and throws away the
rest of the plan.

## 5. The observation is symbolic, and it carries memory the agent has not got

Crafter's observation is a 64 × 64 × 3 image. This game's is symbolic (the idea
names Craftax-Symbolic as what makes LLM play feasible), and it **adds** two
things Crafter does not have: a 16 × 16 downsampled **region map** of what the
cog has explored, and a **`nearest` dictionary** of the closest known cell of
each notable kind. An LLM re-prompted fresh each turn has no hidden state, so
the game keeps the map for it.

**Partial observability is untouched**: an unexplored cell stays `?` until the
cog walks somewhere it can see it from, and creatures are **never** remembered
— they appear only in `view` and in `threats`, both of which are current.

## 6. Reward shape

Crafter's per-step reward is `+1` per new achievement with `±0.1` for health
changes. The league needs one rankable integer, so the score is

    scores[0] = 10000 * achievementsUnlocked + survivalTicks

— achievements dominate (1344 < 10 000), survival is purely the tie-break, and
the health shaping is dropped entirely: it exists to shape RL gradients, not to
rank policies.

## 7. Semantics stated because they are the ones an implementer guesses wrong

- `move_<dir>` sets the facing **and** steps, and a blocked move still turns.
- **Trees are infinite**: a `do` on a tree yields wood and leaves the tree.
- **Mining stone leaves walkable `path`** — that is how a tunnel is dug.
- **Lava is walkable.** Stepping in is instant death, not something the physics
  prevents; `place_stone` over it is how you cross.
- Crafting requires a `table` within **Chebyshev distance 1**, and the two iron
  recipes a `furnace` within 1 as well.

## 8. `maxGames = 1`

The starter's multi-game episode is not used: a survival run has no side to
swap.

---

## Divergences from this repo's own design note

The design note is committed verbatim at
`docs/plans/2026-08-28-crafter-design.md`. Three things in the implementation
depart from it, and each is here rather than silently in the code.

### A. The playability post-pass has a sixth step: **connectivity**

The note's five steps guarantee a tree, water and stone **exist** within reach
of spawn. They do not guarantee the cog can **walk** to one, and 15 of 60
`standard` seeds spawned the cog on a three-by-three grass island in a lake
with all the wood on the far shore — unwinnable, which is exactly what the
post-pass exists to prevent ("every seed is completable").

Steps 2-5 are therefore run **together, to a fixed point** (at most three
sweeps; the second is a no-op on any seed the first settled). Steps 2-4 place a
tree, water and stone within reach if the generator left none, and step 5 is a
deterministic **connectivity carve**: for each of tree, water and stone in that
order, if no cell of that kind touches the land region reachable from spawn, an
L-shaped corridor of `sand` is carved to the nearest one — horizontal first,
then vertical, never through the bedrock ring and never over the forced 3 × 3
grass at spawn. The two halves are interdependent in both directions: a
corridor sands over whatever is in the way, which can take the only tree step 2
forced, and a replacement tree can in turn sit off the reachable land. One
ordered pass leaves both holes open.

The corridor **does** sand over coal, iron and diamond when they are in the
way. A corridor with one unsanded cell in it is not a corridor: on seed 105 a
single coal cell severed the only route to the only reachable tree, and no cog
can mine coal before it has the wood for a pickaxe. The **ore minima are step
6, after this**, so any count a corridor spends is restored.

`oreHost` gained a fallback for the same reason: a seed whose only stone is the
single cell step 4 forced would otherwise spend it on coal and end with no iron
and no diamond. When there is no stone left the ore goes to the
highest-mountain walkable cell at least ten cells from spawn.

`tests/test_crafter_world.nim` items 2 and 3 are what hold this: over 200 seeds
of both variants the invariants hold, a **reachable** tree, water and stone
still exist after the whole post-pass, and over 60 seeds of each a
full-knowledge reference solver (test-only, never shipped in the image) reaches
`collect_diamond`.

### B. The glyph vocabulary is **twenty-one**, not twenty

Fifteen terrains + four creatures + `@` + `?` = 21. The note's prose says
"twenty"; its own legend block lists twenty-one, and twenty-one is what the sim
emits and what `tests/test_crafter_world.nim` pins.

### C. The terrain digest folds by **XOR**, not by a sequential mix

The note writes the incremental digest as
`terrainHash = mixHash(terrainHash, x, y, oldKind, newKind)` and then asks
(§Tests item 33) for the incremental value to **equal** a fresh fold over all
4096 cells. A sequential mix cannot satisfy that: the running value depends on
the order the mutations happened in, the fold does not.

So the digest is an **XOR of per-cell hashes**. XOR is its own inverse, so a
mutation is `digest xor cellDigest(old) xor cellDigest(new)` and the two are
genuinely equal — which is what makes the optimisation provable rather than
merely plausible.

### D. The baseline tunables are the sweep's pick, and the sweep moved two of them

The note's prose names "the sleep length `12`" and "the explore step count `3`"
as the tunables. They are a **parameter object chosen by a sweep, not guessed**
(the note's own rule), and the sweep in `tools/tune_baselines.nim` picks
`sleepTicks = 8` and `exploreSteps = 2`; `tools/ci/baseline_tuning.json`
records the grid and `tests/test_crafter_driver.nim` asserts the shipped
defaults still equal it.

The sweep also carries a **tunable the note does not name**, `restThreshold`,
and `forager`'s rules 1 and 4 differ in shape from the note's ladder:

- **Rule 1 (under attack)** — the note's middle branch is "if `stone >= 1` and
  the cell between them is placeable: `move` to face it, `place_stone`". The
  implementation fights instead: `do` × 3 if the cog already faces the
  hostile, else `move` toward it (which only turns, because a creature blocks
  the step) and `do` × 3, else back away by BFS to the reachable known cell
  farthest from it. Two of the twenty-two achievements (`defeat_zombie`,
  `defeat_skeleton`) are only reachable by fighting, and a baseline that walls
  itself in at Chebyshev 2 never unlocks either.
- **Rule 4 (night shelter)** — fires on
  `(not daylight and energy <= restThreshold) or energy <= 2`, where the note's
  rule 4 has no energy condition at all. Sleeping at every nightfall regardless
  of energy costs a `forager` most of the dark half of the episode; the energy
  condition is what makes it a REST rule. It also emits **one** `place_stone`,
  not the note's `min(4, stone)`: `move_<dir>` steps into a walkable cell and
  every open side is walkable, so "turn to face an open side" is not
  expressible in the action set — the only side a cog can wall off without
  walking out of its own hole is the one it is already facing. It seals that
  one, and up to `shelterStones` of them across consecutive turns.

### E. `wanderer` rotates past lava rather than blindly

The note describes `wanderer` as rotating the facing clockwise whenever the
cell ahead is not traversable. Taken literally that walks the control policy
into lava on the first rotation — `move` steps into any *walkable* cell and
lava is walkable. It rotates **past** known lava instead, which is the smallest
change that keeps it a four-line reactive control and not a suicide.

### F. The `directive` record has a size cap the note does not name

`MaxDirectiveRunes` (`src/crafter/sim_types.nim`) caps the whole serialised
`directive` record. The note caps `say` (160 runes) and `notes` (400) but puts
no bound on the record, and an unbounded record is an unbounded replay.

The cap is **6000 runes**, sized so that a whole observation (≈3800 runes: the
9 × 9 window, the 16 × 16 region, the legend, 22 achievement names, up to 24
landmarks and the executed queue) plus a full-cap `say` fits with room to
spare, because the note's reason for mirroring the observation into the record
is that "the replay explains every decision". `say` shrinks first and the
`view` is dropped only if a record cannot fit with no `say` at all — which no
observed episode reaches.
