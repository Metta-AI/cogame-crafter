# Rules

## The world

- **`worldSize` = 64.** A 64 x 64 grid indexed `(x, y)`, `x` the column
  0..63 west -> east and `y` the row 0..63 north -> south. `(0, 0)` is the
  north-west corner.
- The outermost ring is **bedrock** — impassable, unmineable, unplaceable — so
  the cog can never leave the world. The playable interior is 62 x 62 = 3844
  cells; `results.cellsTotal` is the whole grid, **4096**.
- The cog spawns at **(32, 32) facing down**, on a 3 x 3 block of grass the
  generator forces.
- A cell holds **exactly one terrain and at most one creature**. The terrain
  table is in the README.

## Generation (seeded, integer only, no floats)

Four integer value-noise fields — `mountain`, `water`, `tree`, `cave` — each
built on a lattice of stride 8 whose corner values are
`mix64(seed, fieldSalt, gx, gy) mod 1024`, bilinearly interpolated in 16-bit
fixed point. For each interior cell, first match wins:

1. `M > mountainThreshold`: cave floor / lava / diamond / iron / coal / stone
2. `W > 640` -> water, 3. `W > 590` -> sand, 4. `T > 700` -> tree,
5. else grass.

A **playability post-pass** then runs, deterministically and in this order: the
3 x 3 block at spawn is forced to grass; a tree, water and stone are forced
within Chebyshev 12 / 12 / 20 if none exists; a **connectivity carve** joins
spawn to the nearest tree, water and stone it cannot walk to; and the global
minima (>= 5 coal, >= 3 iron, >= 1 diamond) are filled from the deepest stone.

**Every seed is completable**, the world is a pure function of `(seed, variant)`
— nothing the policy does can shift a draw — and the seat is never told any of
it. See `docs/PORTING-CRAFTER.md` for the connectivity carve's provenance.

## Day, night and the creatures

A tick is **day** when `tick mod dayLength < dayFraction` and **night**
otherwise; `day = tick div dayLength + 1`.

| Creature | HP | Spawns on | When | Cap | Moves | Hurts you |
|---|---|---|---|---|---|---|
| cow `U` | 3 | grass | day only | `maxCows` | 1 step every 4th tick, a seeded direction | never |
| zombie `Z` | 5 | grass or sand | night only | `maxZombies` | 1 step every 2nd tick, greedily toward the cog | 2 awake, **5 asleep**, at most once per 5 ticks, from a 4-adjacent cell |
| skeleton `K` | 3 | cave floor | any time | `maxSkeletons` | 1 step every 3rd tick, **only onto cave floor** | shoots an arrow |
| arrow `^` | — | — | — | — | 1 cell per tick | 2 damage on entering the cog's cell, then vanishes |

**One spawn attempt per kind per tick**, never a retry loop, and never within
Chebyshev 6 of the cog — so nothing ever pops into the 9 x 9 view.

**Zombies burn at dawn.** On the first tick of each day every zombie whose cell
is not cave floor is removed. That is what makes night, and only night,
dangerous.

**Fighting.** `do` facing a creature deals 1 damage bare-handed, 2 with a wood
sword, 3 with stone, 5 with iron.

## Vitals

Each of `health`, `food`, `drink`, `energy` is an integer 0..9, all starting at
9. Every tick, in this order:

1. `food -= 1` when `tick mod 40 == 0`
2. `drink -= 1` when `tick mod 30 == 0`
3. `energy -= 1` when AWAKE and `tick mod 50 == 0`
4. **regenerate**: if all three are positive and `tick mod 25 == 0`,
   `health += 1`
5. **starve**: for each of food, drink, energy that is exactly 0, if
   `tick mod 10 == 0`, `health -= 1`. Three zeroed vitals cost 3 health on the
   same tick.

9 drink lasts 270 ticks, 9 food 360, 9 energy 450. In a 1344-tick episode the
cog must drink about five times, eat about four times and sleep about three
times — which is exactly why `wake_up`, `eat_cow`, `eat_plant` and
`collect_drink` are achievements and not distractions.

## The turn, and the tick

Per **command turn**: the observation is built, one LLM request is issued
(attempt-1 deadline 6 s), retried **once** (3 s), and on a second failure the
**`forager`** scripted plan is computed server-side and a `fallback` record is
written. The reply's actions are validated (invalid entries are **dropped**,
never rewritten), the macros are expanded against the known map **as of turn
start**, and the queue is truncated to 24 primitives. Nothing carries over.

Then, for each of the next `turnTicks` ticks:

1. `tick += 1`
2. pop the next primitive; an empty queue is a real `noop`
3. apply the primitive
4. vitals, the five steps above
5. world tick: saplings ripen, the phase is recomputed, zombies burn at dawn
6. spawns: one bounded attempt each for cow, zombie, skeleton
7. creatures act, in the stable order: arrows, skeletons, zombies, cows
8. achievements: a newly true predicate is recorded and stamped
9. death check
10. visibility: the 9 x 9 window is merged into the known map
11. the tick is mixed into `gameHash`
12. **flinch**: damage from a creature, an arrow or lava (or an episode end)
    **breaks out of the tick loop** — the rest of the turn is discarded.
    Starvation damage does **not** flinch.

## Visibility

`viewSize` = 9. The view is the 9 x 9 square centred on the cog, **in world
orientation** — never rotated to the heading. **There is no occlusion**:
everything in the box is visible, night or day.

The **known map** is a 64 x 64 array of last-observed terrain plus the tick it
was last observed. A cell never in a view stays `?` forever. **Creatures are
never remembered**: they appear only in `view` and in `threats`, both of which
are current.

## End conditions

The episode ends at the first of **death**, **all twenty-two unlocked**, the
**turn cap** (56), the **tick cap** (1344), or the **wall-clock stop** (660 s).

`results.reason` is a closed enum of exactly three values:

- **`complete`** — death, allUnlocked, turnCap or tickCap. **A death is
  `complete`, not a failure**: dying of a zombie bite on night four having
  unlocked twelve achievements is the game working.
- **`deadline`** — the wall-clock stop fired. Everything unlocked so far still
  scores; the budget guard drops the seat to scripted play two turns before the
  stop, so this should be unreachable in practice.
- **`fault`** — always a defect; CI asserts it never occurs on the fixture seeds.

`results.endRule` is its own closed enum:
`death | allUnlocked | turnCap | tickCap | wallClock | fault`, and
`results.deathCause` is
`zombie | skeleton | arrow | lava | starvation | thirst | exhaustion | none`.
