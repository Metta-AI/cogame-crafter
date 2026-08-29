# cogame-crafter

**One cog wakes at dawn in the middle of a 64 × 64 procedurally generated world
it can see nine cells of.** It is hungry, thirsty and tired, and there is a list
of **twenty-two things it has never done**: chop wood, put down a crafting
table, make a wooden pickaxe, mine stone, make a stone pickaxe, build a furnace,
smelt an iron pickaxe, and — at the bottom of the tech tree — cut a diamond out
of the rock. It also has to eat, drink, sleep, and survive the zombies that come
out of the grass when the sun goes down.

Every tick it does one of seventeen things. **The only number the league reads
is how many of the twenty-two it unlocked before it died.**

The whole game is the tension between the tree and the clock: every step down
the tech tree costs ticks you needed for water, and every night you sleep
through is a night you did not spend mining.

*A policy is just a prompt.* Both champions are `PLAYER_PROMPT` strategies; the
LLM call is made by the **game** server, and the seat container is a thin
registrar.

## The world

`64 × 64` cells, the whole outer ring **bedrock**, so the playable interior is
62 × 62. A cell holds exactly one terrain and at most one creature.

| Terrain | Glyph | Walkable | Mined by `do` | Yields | Becomes |
|---|---|---|---|---|---|
| grass | `.` | yes | yes (1-in-10) | 1 sapling | grass |
| sand | `,` | yes | no | — | — |
| water | `~` | no | yes | +1 drink | water |
| stone | `#` | no | needs a wood pickaxe | 1 stone | `path` |
| cave floor | `=` | yes | no | — | — |
| tree | `T` | no | bare hands | 1 wood | tree (**infinite**) |
| coal | `c` | no | needs a wood pickaxe | 1 coal | `path` |
| iron | `i` | no | needs a **stone** pickaxe | 1 iron | `path` |
| diamond | `D` | no | needs an **iron** pickaxe | 1 diamond | `path` |
| lava | `!` | **yes** | no | — | stepping in is **instant death** |
| bedrock | `B` | no | no | — | — |
| table | `t` | no | no | — | — (placed) |
| furnace | `f` | no | no | — | — (placed) |
| sapling | `p` | no | no | — | ripens after 120 ticks |
| ripe plant | `Y` | no | yes | +6 food | sapling |

`U` is a cow, `Z` a zombie, `K` a skeleton, `^` an arrow in flight; `@` is the
cog and `?` is a cell it has never seen. Those twenty-one glyphs are the whole
vocabulary the seat ever reads, and the whole vocabulary the viewer's inset ever
draws.

## The seventeen actions

Exactly Crafter's seventeen, by name, and nothing else is a primitive:

`noop`, `move_left`, `move_right`, `move_up`, `move_down`, `do`, `sleep`,
`place_stone`, `place_table`, `place_furnace`, `place_plant`,
`make_wood_pickaxe`, `make_stone_pickaxe`, `make_iron_pickaxe`,
`make_wood_sword`, `make_stone_sword`, `make_iron_sword`.

A policy sends up to **12 actions per turn**, which the driver expands into at
most **24 primitives** — one per tick — plus two macros (`goto`, `move`) and an
`n` multiplier on `do` and `sleep`. **Any hit ends the turn early** and throws
away the rest of the plan, which is what keeps batching from removing
reactivity. See [`docs/ACTIONS.md`](docs/ACTIONS.md).

## Scoring

```
scores[0] = 10000 * achievementsUnlocked + survivalTicks
```

Higher is better and every term only ever adds. One more achievement is worth
10 000 and the largest possible survival term is 1344, so **achievements always
dominate** and survival is purely the tie-break. `results.win[0]` is
`achievementsUnlocked >= parAchievements` — a "did the cog clear the bar" flag,
not a duel.

The paper's geometric-mean aggregate is a **cross-episode** statistic and is
computed by [`tools/crafter_score.py`](tools/crafter_score.py) over a directory
of `results.json` files. It is **not** what the ladder ranks. See
[`docs/ACHIEVEMENTS.md`](docs/ACHIEVEMENTS.md).

## Variants

Both are `num_agents: 1`, `maxTurns: 56`, `turnTicks: 24`, `maxTicks: 1344`.

| Variant | day / night | zombies | cows | mountain | par |
|---|---|---|---|---|---|
| `standard` | 128 / 64 | 8 | 12 | 700 | 8 |
| `longnight` | 80 / 80 | 12 | 8 | 660 | 6 |

`standard` is the canonical Crafter world: seven day/night cycles, twice as much
day as night, plenty of cows. `longnight` is the survival-pressure variant —
half the episode dark, half again as many zombies, and ore closer to the surface
so the tech tree stays reachable in the dark.

## Policies

One image, two entrypoints, and the whole policy set switched by environment:

```bash
coworld upload-policy coworld-crafter:latest --name my-crafter \
  --run /bin/crafter-player --secret-env PLAYER_PROMPT="<your strategy>"
```

| Env | Effect |
|---|---|
| `PLAYER_PROMPT` | this seat is an **LLM** seat; the prompt is its whole strategy |
| `PLAYER_SCRIPTED` | `forager` \| `wanderer` — this seat is scripted |
| `PLAYER_POLICY_LABEL` | a free label for the replay's `register` record |

A seat that sets neither is `forager`, which is also the server-side fallback
whenever a seat's LLM call fails twice — so no failure mode ever leaves the cog
without an action.

The shipped set (`tools/ci/policies.json`) is two `PLAYER_PROMPT` champions —
`crafter-techtree` (climb the tree, everything else is logistics) and
`crafter-homesteader` (build a base, then raid out of it) — plus the two
scripted fillers.

## Two name spaces

In-game the seat is **`Alpha`**, and that alias is the only name that appears in
an observation, in a prompt, in a `say`, or on the board. Its **real
policy/player name** lives only in `results.names`, in the replay's join record,
and spectator-side in the viewer's scorebug plate and endcard.

## Replays

The replay is the starter's binary `COWLDCRF` format: the resolved config, the
join, the per-turn plans, the chat records and **one `gameHash` per tick**. The
whole 64 × 64 world, every ore, every creature and every achievement tick is
**re-generated in the browser** from the seed and the variant by the *same sim
module* compiled to WebAssembly — the static replay bundle, never a pod.

```bash
python3 tools/replay_summary.py path/to/episode.replay | jq .
```

## Build and test

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim c -r --path:src tests/shards/tests.nim     # every shard
docker build -t coworld-crafter:ci . && ./tools/ci/docker_smoke.sh coworld-crafter:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

`.github/workflows/ci.yml` is the only harness that matters: it runs every
`tests/*.nim` in debug **and** release, builds the production image and plays a
real episode in raw Docker, then builds the wasm bundle and **opens it in
headless chromium** against the replay that episode produced.

## Documentation

- [`docs/RULES.md`](docs/RULES.md) — the world, the clock, the vitals, the
  creatures, the end conditions
- [`docs/ACTIONS.md`](docs/ACTIONS.md) — the reply schema and every per-field cap
- [`docs/ACHIEVEMENTS.md`](docs/ACHIEVEMENTS.md) — the twenty-two, in order
- [`docs/PORTING-CRAFTER.md`](docs/PORTING-CRAFTER.md) — **what this is and is
  not a port of**
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — the Coworld contract
- [`docs/plans/2026-08-28-crafter-design.md`](docs/plans/2026-08-28-crafter-design.md)
  — the design note this repo implements, verbatim
