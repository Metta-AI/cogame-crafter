# The 22 achievements

The canonical Crafter list, **by name and in the canonical order**. This
ordering is `results.achievementIds`, the order of the viewer's checklist and
the order of the `locked` list in the observation.

Each unlocks **once**, permanently, the tick its predicate first becomes true,
and is **never revoked**. `results.achievementUnlocked[i]` is the boolean and
`results.achievementTick[i]` is the tick it lit, or `-1`.

**The only number the league reads is how many of them you unlocked before you
died:** `scores[0] = 10000 * achievementsUnlocked + survivalTicks`. One more
achievement is worth 10 000 and the largest possible survival term is 1344, so
achievements always dominate and survival is purely the tie-break.

| # | id | Unlocks when | What it needs first |
|---|---|---|---|
| 1 | `collect_wood` | a `do` on a `tree` yields wood | nothing — bare hands on a tree |
| 2 | `place_table` | a `table` is placed | 1 wood |
| 3 | `eat_cow` | a cow is reduced to 0 HP by the cog | a cow in reach; `do` it two to four times |
| 4 | `collect_sapling` | a `do` on `grass` yields a sapling (a 1-in-10 draw) | nothing; the draw is 1-in-10 per `do` on grass |
| 5 | `collect_drink` | a `do` on `water` raises `drink` | water in front of you |
| 6 | `make_wood_pickaxe` | the recipe succeeds | 1 wood, a table within one cell |
| 7 | `make_wood_sword` | the recipe succeeds | 1 wood, a table within one cell |
| 8 | `place_plant` | a sapling is planted | 1 sapling, facing grass |
| 9 | `defeat_zombie` | a zombie is reduced to 0 HP by the cog | a sword helps; bare hands do 1 damage a tick and a zombie has 5 HP |
| 10 | `collect_stone` | a `do` on `stone` yields stone | a wood pickaxe |
| 11 | `place_stone` | a stone is placed | 1 stone |
| 12 | `eat_plant` | a `do` on a `ripe plant` raises `food` | a sapling you planted 120 ticks ago |
| 13 | `defeat_skeleton` | a skeleton is reduced to 0 HP by the cog | a sword, and a skeleton — they live on cave floor |
| 14 | `make_stone_pickaxe` | the recipe succeeds | 1 wood + 1 stone, a table within one cell |
| 15 | `make_stone_sword` | the recipe succeeds | 1 wood + 1 stone, a table within one cell |
| 16 | `wake_up` | a run of >= 1 `sleep` ticks that began with `energy < 9` ends with `energy == 9` | sleep from below full energy until it reaches 9 |
| 17 | `place_furnace` | a `furnace` is placed | 1 stone |
| 18 | `collect_coal` | a `do` on `coal` yields coal | a wood pickaxe |
| 19 | `collect_iron` | a `do` on `iron` yields iron | a **stone** pickaxe |
| 20 | `make_iron_pickaxe` | the recipe succeeds | 1 wood + 1 coal + 1 iron, a table **and** a furnace within one cell |
| 21 | `make_iron_sword` | the recipe succeeds | 1 wood + 1 coal + 1 iron, a table **and** a furnace within one cell |
| 22 | `collect_diamond` | a `do` on `diamond` yields a diamond | an **iron** pickaxe |

## The tech tree, as a shape

```
  chop a tree            -> wood
  place_table (1 wood)   -> you can now craft, but only while STANDING NEXT TO IT
  make_wood_pickaxe (1 wood)      make_wood_sword (1 wood)
  mine stone (needs wood pickaxe) -> stone
  make_stone_pickaxe (1 wood + 1 stone)   make_stone_sword (1 wood + 1 stone)
  place_furnace (1 stone)
  mine coal (wood pickaxe), mine iron (STONE pickaxe)
  make_iron_pickaxe / make_iron_sword (1 wood + 1 coal + 1 iron, needs table
    AND furnace both within one cell of you)
  mine diamond (needs IRON pickaxe)
```

Six of the twenty-two are not on the tree at all — `eat_cow`,
`collect_drink`, `collect_sapling`, `place_plant`, `eat_plant` and `wake_up`
are the survival half — and two more, `defeat_zombie` and `defeat_skeleton`,
are the price of being outside after dark. That split is the whole game: every
step down the tree costs ticks you needed for water, and every night you sleep
through is a night you did not spend mining.

## The paper's aggregate

Crafter's published score

    S = exp( (1/22) * sum_i ln(1 + 100 * p_i) ) - 1

where `p_i` is the **success rate** of achievement `i` across a run of
episodes, is a **cross-episode** aggregate: a single episode has no success
rate, only a boolean per achievement. This coworld therefore reports the
per-episode integer above — which is what a league round can rank — plus the
raw material the aggregate needs, and `tools/crafter_score.py` does the
aggregation over a directory of `results.json` files:

```bash
python3 tools/crafter_score.py path/to/results/
```

It needs at least ten episodes to mean anything, and **it is not what the
ladder ranks**.
