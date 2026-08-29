## The sim — design note §Tests items 6..18.
##
## The seventeen primitives, lava, the vitals block, the creatures, the 9 x 9
## window, the 16 x 16 region map, the `goto` BFS, the twenty-two
## achievements, the turn and tick order, scoring, the end conditions, the
## geometric-mean aggregate and the tick budget.

import std/[json, math, os, osproc, random, strutils, times, unittest]
import crafter/[sim, driver, directives, baselines]
import helpers

proc fresh(seed = 42, variant = "standard"): SimServer =
  startedSim(testConfig(variant, seed))

proc clearAround(sim: var SimServer, radius = 3, terrain = tGrass) =
  for dy in -radius .. radius:
    for dx in -radius .. radius:
      sim.world.setAt(sim.cog.x + dx, sim.cog.y + dy, terrain)
  sim.terrainHash = sim.world.terrainDigest()

proc place(sim: var SimServer, dx, dy: int, terrain: Terrain) =
  sim.world.setAt(sim.cog.x + dx, sim.cog.y + dy, terrain)
  sim.terrainHash = sim.world.terrainDigest()

proc oneTick(sim: var SimServer, primitive: Primitive) =
  ## One tick with exactly one primitive, through the real tick loop.
  discard sim.beginTurn()
  sim.installPlan(@[primitive], false, 0, 0)
  sim.stepTick()
  sim.pending.setLen(0)
  sim.turnActive = false
  sim.queue = @[]

suite "the seventeen primitives":
  test "move turns, then steps only into a walkable creature-free cell":
    ## Item 6, first clause. This is the semantics an implementer guesses
    ## wrong: a blocked `move` still TURNS the cog.
    var sim = fresh()
    sim.clearAround()
    sim.place(0, -1, tStone)
    let start = (sim.cog.x, sim.cog.y)
    sim.oneTick(pMoveUp)
    check sim.cog.facing == fUp
    check (sim.cog.x, sim.cog.y) == start        ## turned, did not step
    sim.oneTick(pMoveRight)
    check sim.cog.facing == fRight
    check sim.cog.x == start[0] + 1
    ## A creature in the target cell blocks the step too.
    sim.herd.list.add(Creature(kind: ckCow, x: sim.cog.x + 1, y: sim.cog.y,
                               hp: 3, alive: true))
    let before = (sim.cog.x, sim.cog.y)
    sim.oneTick(pMoveRight)
    check (sim.cog.x, sim.cog.y) == before

  test "do resolves a creature before the terrain":
    ## Item 6, second clause.
    var sim = fresh()
    sim.clearAround()
    sim.place(0, 1, tTree)
    sim.cog.facing = fDown
    sim.herd.list.add(Creature(kind: ckCow, x: sim.cog.x, y: sim.cog.y + 1,
                               hp: 3, alive: true))
    let wood = sim.cog.inventory[rWood]
    sim.oneTick(pDo)
    check sim.cog.inventory[rWood] == wood      ## the cow was hit, not the tree
    check sim.damageDealt == 1

  test "every recipe checks its costs and its table/furnace adjacency":
    ## Item 6, third clause, and the deliberate near misses of item 13.
    var sim = fresh()
    sim.clearAround()
    sim.cog.inventory[rWood] = 9
    sim.cog.inventory[rStone] = 9
    sim.cog.inventory[rCoal] = 9
    sim.cog.inventory[rIron] = 9
    ## No table: every craft is a no-op that still costs the tick.
    let tick = sim.tickCount
    sim.oneTick(pMakeWoodPickaxe)
    check not sim.cog.tools[toWoodPickaxe]
    check sim.tickCount == tick + 1
    sim.place(1, 0, tTable)
    sim.oneTick(pMakeWoodPickaxe)
    check sim.cog.tools[toWoodPickaxe]
    check sim.cog.inventory[rWood] == 8
    ## A table but no furnace: the iron recipes still refuse.
    sim.oneTick(pMakeIronPickaxe)
    check not sim.cog.tools[toIronPickaxe]
    sim.place(-1, 0, tFurnace)
    sim.oneTick(pMakeIronPickaxe)
    check sim.cog.tools[toIronPickaxe]
    ## Crafting an owned tool costs nothing and still costs the tick.
    let wood = sim.cog.inventory[rWood]
    sim.oneTick(pMakeIronPickaxe)
    check sim.cog.inventory[rWood] == wood
    ## Costs are enforced.
    sim.cog.tools[toStoneSword] = false
    sim.cog.inventory[rStone] = 0
    sim.oneTick(pMakeStoneSword)
    check not sim.cog.tools[toStoneSword]

  test "every place_* checks its cost and its target terrain":
    var sim = fresh()
    sim.clearAround()
    sim.cog.facing = fRight
    ## No stone: place_stone is a no-op.
    sim.oneTick(pPlaceStone)
    check sim.world.at(sim.cog.x + 1, sim.cog.y) == tGrass
    sim.cog.inventory[rStone] = 2
    sim.oneTick(pPlaceStone)
    check sim.world.at(sim.cog.x + 1, sim.cog.y) == tStone
    check sim.cog.inventory[rStone] == 1
    ## place_table refuses a non-buildable target.
    sim.cog.inventory[rWood] = 1
    sim.oneTick(pPlaceTable)
    check sim.world.at(sim.cog.x + 1, sim.cog.y) == tStone
    check sim.cog.inventory[rWood] == 1
    ## place_plant needs GRASS, not sand or path.
    sim.cog.facing = fLeft
    sim.place(-1, 0, tSand)
    sim.cog.inventory[rSapling] = 1
    sim.oneTick(pPlacePlant)
    check sim.world.at(sim.cog.x - 1, sim.cog.y) == tSand
    sim.place(-1, 0, tGrass)
    sim.oneTick(pPlacePlant)
    check sim.world.at(sim.cog.x - 1, sim.cog.y) == tSapling

  test "sleep adds energy, noop mutates nothing":
    var sim = fresh()
    sim.clearAround()
    sim.cog.vitals[vEnergy] = 4
    sim.oneTick(pSleep)
    check sim.cog.energy() == 5
    check sim.cog.asleep
    let snapshot = sim.cog
    sim.oneTick(pNoop)
    check not sim.cog.asleep                    ## any other primitive wakes it
    check sim.cog.x == snapshot.x and sim.cog.y == snapshot.y
    check sim.cog.inventory == snapshot.inventory

suite "lava, vitals and creatures":
  test "lava kills instantly, and a placed stone makes it safe":
    ## Item 7.
    var sim = fresh()
    sim.clearAround()
    sim.place(0, 1, tLava)
    sim.cog.vitals[vHealth] = VitalMax
    sim.cog.facing = fDown
    sim.oneTick(pMoveDown)
    check sim.cog.health() == 0
    check sim.deathCause == dcLava
    check sim.endRule == edDeath
    ## place_stone over lava makes it walkable and no longer fatal.
    var safe = fresh()
    safe.clearAround()
    safe.place(0, 1, tLava)
    safe.cog.facing = fDown
    safe.cog.inventory[rStone] = 1
    safe.oneTick(pPlaceStone)
    check safe.world.at(safe.cog.x, safe.cog.y + 1) == tStone
    safe.cog.tools[toWoodPickaxe] = true
    safe.oneTick(pDo)                            ## mine it back to path
    check safe.world.at(safe.cog.x, safe.cog.y + 1) == tPath
    safe.oneTick(pMoveDown)
    check safe.cog.health() == VitalMax

  test "the five vitals steps, in order, over a long synthetic run":
    ## Item 8.
    var cog = newCog(SpawnX, SpawnY)
    ## Start hurt, so regeneration has somewhere to go.
    cog.vitals[vHealth] = 1
    var drains = [0, 0, 0]
    var regens = 0
    var starves = 0
    for tick in 1 .. 1344:
      let before = cog.vitals
      let outcome = cog.stepVitals(tick, 40, 30, 50, 25, 10)
      if outcome.drained[vFood]: inc drains[0]
      if outcome.drained[vDrink]: inc drains[1]
      if outcome.drained[vEnergy]: inc drains[2]
      if outcome.regenerated: inc regens
      for vital in [vFood, vDrink, vEnergy]:
        if outcome.starved[vital]: inc starves
      for vital in Vital:
        check cog.vitals[vital] in 0 .. VitalMax
      discard before
    ## 9 food lasts 360 ticks, 9 drink 270, 9 energy 450.
    check drains == [9, 9, 9]
    check regens > 0
    check starves > 0
    ## The food/drink/energy -> deathCause mapping, in the resolution order.
    check starvationCause(vFood) == dcStarvation
    check starvationCause(vDrink) == dcThirst
    check starvationCause(vEnergy) == dcExhaustion
    ## Regeneration only when all three are positive.
    var full = newCog(0, 0)
    full.vitals[vHealth] = 3
    full.vitals[vFood] = 0
    let blocked = full.stepVitals(25, 40, 30, 50, 25, 10)
    check not blocked.regenerated

  test "three zeroed vitals cost three health on the same tick":
    var cog = newCog(0, 0)
    cog.vitals[vFood] = 0
    cog.vitals[vDrink] = 0
    cog.vitals[vEnergy] = 0
    cog.vitals[vHealth] = 9
    discard cog.stepVitals(10, 40, 30, 50, 25, 10)
    check cog.health() == 6

  test "creature spawning is bounded, terrain-correct and never in view":
    ## Item 9, first clause.
    var sim = fresh()
    var herd = Herd()
    for tick in 1 .. 4000:
      for kind in [ckCow, ckZombie, ckSkeleton]:
        let before = herd.list.len
        discard herd.trySpawn(sim.world, kind, 4, sim.config.seed, tick,
                              sim.cog.x, sim.cog.y)
        check herd.list.len - before <= 1        ## ONE attempt per kind
      check herd.countOf(ckCow) <= 4
      check herd.countOf(ckZombie) <= 4
      check herd.countOf(ckSkeleton) <= 4
    for creature in herd.list:
      check chebyshev(creature.x, creature.y, sim.cog.x, sim.cog.y) >= 6
      case creature.kind
      of ckCow: check sim.world.at(creature.x, creature.y) == tGrass
      of ckZombie: check sim.world.at(creature.x, creature.y) in {tGrass, tSand}
      of ckSkeleton: check sim.world.at(creature.x, creature.y) == tPath
      of ckArrow: check false

  test "zombies burn at dawn only when they are not on path":
    ## Item 9, second clause.
    var sim = fresh()
    sim.clearAround(4)
    sim.place(3, 0, tPath)
    sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 2,
                               y: sim.cog.y, hp: 5, alive: true))
    sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 3,
                               y: sim.cog.y, hp: 5, alive: true))
    let burned = sim.herd.burnAtDawn(sim.world)
    check burned == 1
    sim.herd.compact()
    check sim.herd.list.len == 1
    check sim.world.at(sim.herd.list[0].x, sim.herd.list[0].y) == tPath

  test "zombie damage is 2 awake and 5 asleep, with a 5-tick cooldown":
    ## Item 9, third clause.
    for asleep in [false, true]:
      var sim = fresh()
      sim.clearAround()
      sim.cog.asleep = asleep
      sim.cog.vitals[vHealth] = VitalMax
      sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 1,
                                 y: sim.cog.y, hp: 5, lastAct: -99,
                                 alive: true))
      let hits = sim.herd.stepCreatures(sim.world, sim.cog, sim.config.seed, 10)
      check hits.len == 1
      check hits[0].amount == (if asleep: 5 else: 2)
      ## The cooldown: no second hit inside five ticks.
      let again = sim.herd.stepCreatures(sim.world, sim.cog, sim.config.seed, 12)
      check again.len == 0
      let later = sim.herd.stepCreatures(sim.world, sim.cog, sim.config.seed, 16)
      check later.len == 1

  test "skeletons need a clear straight line within 6 and an 8-tick cooldown":
    ## Item 9, fourth clause, and arrow flight.
    var sim = fresh()
    sim.clearAround(6, tPath)
    sim.cog.vitals[vHealth] = VitalMax
    sim.herd.list.add(Creature(kind: ckSkeleton, x: sim.cog.x + 4,
                               y: sim.cog.y, hp: 3, lastAct: -99, alive: true))
    discard sim.herd.stepCreatures(sim.world, sim.cog, sim.config.seed, 20)
    check sim.herd.countOf(ckArrow) == 1
    ## An arrow travels one cell a tick toward the cog.
    let arrow = sim.herd.list[^1]
    check arrow.x == sim.cog.x + 3
    ## Blocked line: no shot.
    var blocked = fresh()
    blocked.clearAround(6, tPath)
    blocked.place(2, 0, tStone)
    blocked.herd.list.add(Creature(kind: ckSkeleton, x: blocked.cog.x + 4,
                                   y: blocked.cog.y, hp: 3, lastAct: -99,
                                   alive: true))
    discard blocked.herd.stepCreatures(blocked.world, blocked.cog,
                                       blocked.config.seed, 20)
    check blocked.herd.countOf(ckArrow) == 0

  test "an arrow vanishes on any obstruction and does 2 damage on the cog":
    var sim = fresh()
    sim.clearAround(4, tPath)
    sim.cog.vitals[vHealth] = VitalMax
    sim.herd.list.add(Creature(kind: ckArrow, x: sim.cog.x + 1, y: sim.cog.y,
                               hp: 1, facing: fLeft, alive: true))
    let hits = sim.herd.stepCreatures(sim.world, sim.cog, sim.config.seed, 5)
    check hits.len == 1
    check hits[0].amount == 2
    check hits[0].by == ckArrow
    sim.herd.compact()
    check sim.herd.countOf(ckArrow) == 0

suite "visibility and the maps":
  test "the 9 x 9 window is nine strings of nine, world-oriented":
    ## Item 10.
    var sim = fresh()
    let rows = sim.viewRows()
    check rows.len == ViewSize
    for row in rows:
      check row.len == ViewSize
    check rows[ViewSize div 2][ViewSize div 2] == CogGlyph
    ## Creature glyphs sit OVER terrain glyphs.
    sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 2,
                               y: sim.cog.y, hp: 5, alive: true))
    let withZombie = sim.viewRows()
    check withZombie[ViewSize div 2][ViewSize div 2 + 2] == 'Z'
    ## No cell outside the box leaks in: the window is exactly the box.
    let origin = viewOrigin(sim.cog.x, sim.cog.y)
    for j in 0 ..< ViewSize:
      for i in 0 ..< ViewSize:
        let
          x = origin.x + i
          y = origin.y + j
        if x == sim.cog.x and y == sim.cog.y:
          continue
        if sim.herd.creatureAt(x, y) >= 0:
          continue
        check withZombie[j][i] == sim.world.at(x, y).glyphOf()

  test "the known map grows only from observed windows, and never remembers a creature":
    var sim = fresh()
    let far = idx(2, 2)
    check not sim.knownMap.cells[far].seen
    sim.herd.list.add(Creature(kind: ckCow, x: sim.cog.x + 1, y: sim.cog.y,
                               hp: 3, alive: true))
    sim.runTurn(@[Action(kind: akNoop, n: 1)])
    ## A cell never in a view stays `?` for the whole episode.
    check not sim.knownMap.cells[far].seen
    check sim.knownMap.knownGlyph(2, 2) == UnseenGlyph
    ## Creatures are never written into the known map.
    check sim.knownMap.known(sim.cog.x + 1, sim.cog.y).terrain ==
      sim.world.at(sim.cog.x + 1, sim.cog.y)

  test "the 16 x 16 region map is sixteen strings of sixteen, by priority":
    ## Item 11.
    var sim = fresh()
    var rows = sim.knownMap.regionRows()
    check rows.len == RegionSize
    for row in rows:
      check row.len == RegionSize
    ## A region with no observed cell is `?`.
    check rows[0][0] == UnseenGlyph
    ## The highest-priority KNOWN terrain wins its region.
    var map: KnownMap
    for terrain in [tGrass, tStone, tTree, tDiamond]:
      var slot = 0
      map.cells[slot].seen = true
      map.cells[slot].terrain = terrain
      rows = map.regionRows()
      check rows[0][0] == terrain.glyphOf()
      ## And a lower-priority neighbour in the same region does not displace it.
      map.cells[1].seen = true
      map.cells[1].terrain = tGrass
      rows = map.regionRows()
      check rows[0][0] == terrain.glyphOf()
      map.cells[1].seen = false
      discard slot

suite "the goto BFS":
  test "the path is unique, never traverses the unknown, and ends facing":
    ## Item 12.
    var sim = fresh()
    sim.clearAround(6)
    sim.revealAll()
    ## A traversable target: the path ends ON it.
    let target = (sim.cog.x + 4, sim.cog.y)
    let walk = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
                              target[0], target[1], 24)
    check walk.ok
    check (walk.x, walk.y) == target
    check walk.primitives.len == 4
    for primitive in walk.primitives:
      check primitive == pMoveRight
    ## The same query twice is the same path: 4-adjacency in the fixed order
    ## up, right, down, left makes it unique.
    let again = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
                               target[0], target[1], 24)
    check again.primitives == walk.primitives
    ## A non-traversable target: the path ends NEXT to it, facing it.
    sim.place(4, 0, tTree)
    sim.revealAll()
    let toTree = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
                                target[0], target[1], 24)
    check toTree.ok
    check (toTree.x, toTree.y) == (sim.cog.x + 3, sim.cog.y)
    check toTree.primitives[^1] == pMoveRight

  test "an unreachable target yields zero primitives and counts unreachable":
    var sim = fresh()
    let far = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y, 2, 2, 24)
    check not far.ok
    check far.primitives.len == 0
    let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
      @[Action(kind: akGoto, x: 2, y: 2, n: 1)], 24, 24)
    check expansion.unreachable == 1
    check expansion.primitives.len == 0

  test "the BFS never routes through water, lava, rock, a tree or a hostile":
    var sim = fresh()
    sim.clearAround(6)
    for terrain in [tWater, tLava, tStone, tTree, tTable, tFurnace, tSapling,
                    tRipePlant, tCoal, tIron, tDiamond, tBedrock]:
      check not KnownMap(cells: block:
        var cells: array[WorldCells, KnownCell]
        cells[idx(5, 5)] = KnownCell(seen: true, terrain: terrain)
        cells).traversable(5, 5)
    ## A known hostile blocks the route.
    sim.revealAll()
    let blocked = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
      sim.cog.x + 4, sim.cog.y, 24, @[idx(sim.cog.x + 1, sim.cog.y),
                                      idx(sim.cog.x, sim.cog.y + 1),
                                      idx(sim.cog.x, sim.cog.y - 1)])
    ## Reaching the target now needs a detour, or is impossible; either way
    ## the first step is never onto the hostile's cell.
    if blocked.ok and blocked.primitives.len > 0:
      check blocked.primitives[0] != pMoveRight

  test "the path never exceeds macroPrimitiveCap":
    var sim = fresh()
    sim.clearAround(20)
    sim.revealAll()
    let walk = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
                              sim.cog.x + 20, sim.cog.y + 20, 24)
    check walk.primitives.len <= 24

suite "achievements, turns and scoring":
  test "each of the twenty-two unlocks once, is never revoked, and stamps its tick":
    ## Item 13.
    var ledger = initLedger()
    for a in Achievement:
      check ledger.tick[a] == -1
      check ledger.recordAchievement(a, 100 + ord(a))
      check not ledger.recordAchievement(a, 999)   ## deduplicated
      check ledger.tick[a] == 100 + ord(a)
    check ledger.count == AchievementCount
    check ledger.allUnlocked()

  test "the near misses do NOT unlock":
    ## Item 13's deliberate near misses.
    ## Crafting with no table nearby.
    var sim = fresh()
    sim.clearAround()
    sim.cog.inventory[rWood] = 4
    sim.oneTick(pMakeWoodPickaxe)
    check not sim.ledger.has(aMakeWoodPickaxe)
    ## Mining iron with only a wooden pickaxe.
    sim.cog.tools[toWoodPickaxe] = true
    sim.place(0, 1, tIron)
    sim.cog.facing = fDown
    sim.oneTick(pDo)
    check not sim.ledger.has(aCollectIron)
    ## Eating an UNRIPE sapling.
    sim.place(0, 1, tSapling)
    let food = sim.cog.food()
    sim.oneTick(pDo)
    check not sim.ledger.has(aEatPlant)
    check sim.cog.food() == food
    ## wake_up after a sleep run that started at FULL energy.
    var rested = fresh()
    rested.clearAround()
    rested.cog.vitals[vEnergy] = VitalMax
    rested.oneTick(pSleep)
    rested.oneTick(pNoop)
    check not rested.ledger.has(aWakeUp)
    ## defeat_zombie when the zombie is not killed BY THE COG.
    var elsewhere = fresh()
    elsewhere.herd.list.add(Creature(kind: ckZombie, x: elsewhere.cog.x + 5,
                                     y: elsewhere.cog.y, hp: 5, alive: true))
    elsewhere.herd.list[0].alive = false
    elsewhere.herd.compact()
    check not elsewhere.ledger.has(aDefeatZombie)

  test "wake_up unlocks when a run that began below full ends at full":
    var sim = fresh()
    sim.clearAround()
    sim.cog.vitals[vEnergy] = 7
    discard sim.beginTurn()
    sim.installPlan(@[pSleep, pSleep, pNoop], false, 0, 0)
    while sim.turnActive and sim.phase == Playing:
      sim.stepTick()
      sim.pending.setLen(0)
    check sim.cog.energy() == VitalMax
    check sim.ledger.has(aWakeUp)

  test "wake_up also unlocks when a bite is what ends the rested run":
    ## §The seventeen actions: "any other primitive wakes it, AND SO DOES
    ## TAKING CREATURE/ARROW DAMAGE". The predicate for achievement 16 is
    ## about the RUN — began below 9, ends at 9 — not about what ended it, so
    ## a zombie that bites a fully rested sleeper still unlocks it.
    var sim = fresh()
    sim.clearAround()
    sim.cog.vitals[vEnergy] = 8
    discard sim.beginTurn()
    sim.installPlan(@[pSleep, pSleep], false, 0, 0)
    sim.stepTick()                        ## asleep, energy 9
    sim.pending.setLen(0)
    check sim.cog.asleep
    check sim.cog.energy() == VitalMax
    check not sim.ledger.has(aWakeUp)
    ## A zombie 4-adjacent, ready to bite on the next tick.
    sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 1, y: sim.cog.y,
                              hp: 5, lastAct: -100, alive: true))
    sim.stepTick()
    sim.pending.setLen(0)
    check not sim.cog.asleep
    check sim.damageTaken > 0
    check sim.ledger.has(aWakeUp)

  test "the turn and tick order, end to end":
    ## Item 14.
    var sim = fresh()
    sim.clearAround(5)
    ## A turn is `turnTicks` ticks: an empty queue empties into `noop`.
    discard sim.beginTurn()
    sim.installPlan(@[pNoop], false, 0, 0)
    while sim.turnActive and sim.phase == Playing:
      sim.stepTick()
      sim.pending.setLen(0)
    check sim.runTick() == sim.config.turnTicks
    check sim.turnsPlayed == 1
    ## A CREATURE HIT breaks the tick loop; starvation damage does not.
    var bitten = fresh()
    bitten.clearAround(3)
    bitten.herd.list.add(Creature(kind: ckZombie, x: bitten.cog.x + 1,
                                  y: bitten.cog.y, hp: 5, lastAct: -99,
                                  alive: true))
    discard bitten.beginTurn()
    bitten.installPlan(@[pNoop, pNoop, pNoop, pNoop, pNoop, pNoop], false, 0, 0)
    while bitten.turnActive and bitten.phase == Playing:
      bitten.stepTick()
      bitten.pending.setLen(0)
    check bitten.interrupts == 1
    check bitten.runTick() < bitten.config.turnTicks
    var starving = fresh()
    starving.clearAround(3)
    starving.cog.vitals[vFood] = 0
    starving.runTurn(@[Action(kind: akNoop, n: 1)])
    check starving.interrupts == 0
    check starving.runTick() == starving.config.turnTicks

  test "the twenty-second achievement ends the episode immediately":
    var sim = fresh()
    for a in Achievement:
      if a == aCollectDiamond:
        continue
      discard sim.ledger.recordAchievement(a, 1)
    sim.clearAround()
    sim.cog.tools[toIronPickaxe] = true
    sim.place(0, 1, tDiamond)
    sim.cog.facing = fDown
    sim.oneTick(pDo)
    check sim.ledger.allUnlocked()
    check sim.phase == GameOver
    check sim.endRule == edAllUnlocked
    check sim.endReason == erComplete

  test "scoring over 500 randomised end states":
    ## Item 15.
    var rng = initRand(7)
    for i in 0 .. 499:
      var sim = initSimServer(testConfig())
      sim.phase = Playing
      sim.gameStartTick = 0
      let unlocked = rng.rand(0 .. AchievementCount)
      var granted = 0
      for a in Achievement:
        if granted >= unlocked:
          break
        discard sim.ledger.recordAchievement(a, 1)
        inc granted
      sim.tickCount = rng.rand(1 .. 1344)
      check sim.score() == 10_000 * unlocked + sim.tickCount
      check sim.score() >= 0
    ## The dominance bound and the extremes.
    check 1344 < 10_000
    check 10_000 * AchievementCount + 1344 == 221_344
    var minimal = initSimServer(testConfig())
    minimal.phase = Playing
    minimal.tickCount = 1
    check minimal.score() == 1

  test "win, winner and par":
    for unlocked in 0 .. AchievementCount:
      var sim = initSimServer(testConfig())
      var granted = 0
      for a in Achievement:
        if granted >= unlocked: break
        discard sim.ledger.recordAchievement(a, 1)
        inc granted
      sim.finish(erComplete, edTurnCap)
      let results = parseJson(sim.runResultsJson())
      let met = unlocked >= sim.config.parAchievements
      check results["win"][0].getBool() == met
      if met:
        check results["winner"].getInt() == 0
      else:
        check results["winner"].kind == JNull

  test "every end condition produces the right endRule and reason":
    ## Item 16.
    block death:
      var sim = fresh()
      sim.clearAround()
      sim.cog.vitals[vHealth] = 1
      sim.cog.vitals[vFood] = 0
      sim.cog.vitals[vDrink] = 0
      while sim.phase == Playing and sim.runTick() < 60:
        sim.runTurn(@[Action(kind: akNoop, n: 1)])
      check sim.endRule == edDeath
      check sim.endReason == erComplete
      check sim.deathCause != dcNone
    block allUnlocked:
      var sim = fresh()
      for a in Achievement:
        discard sim.ledger.recordAchievement(a, 1)
      sim.clearAround()
      sim.runTurn(@[Action(kind: akNoop, n: 1)])
      check sim.endRule == edAllUnlocked
    block turnCap:
      var sim = fresh()
      sim.turnsPlayed = sim.config.maxTurns
      check not sim.beginTurn()
      check sim.endRule == edTurnCap
      check sim.endReason == erComplete
    block tickCap:
      var sim = fresh()
      sim.clearAround()
      sim.tickCount = sim.gameStartTick + sim.config.maxTicks - 1
      sim.runTurn(@[Action(kind: akNoop, n: 1)])
      check sim.endRule == edTickCap
      check sim.endReason == erComplete
    block wallClock:
      var sim = fresh()
      for a in [aCollectWood, aPlaceTable]:
        discard sim.ledger.recordAchievement(a, 5)
      sim.tickCount = sim.gameStartTick + 300
      sim.applyStop(edWallClock, "budget reached")
      check sim.endRule == edWallClock
      check sim.endReason == erDeadline
      ## A wall-clock stop mid-run still scores every achievement so far.
      check sim.achievementsUnlocked() == 2
      check sim.score() == 20_000 + 300
    block fault:
      var sim = fresh()
      sim.applyStop(edFault, "boom")
      check sim.endRule == edFault
      check sim.endReason == erFault

  test "the geometric-mean aggregate":
    ## Item 17: `tools/crafter_score.py` over 50 synthetic results documents.
    let dir = getTempDir() / "crafter-score-test"
    removeDir(dir)
    createDir(dir)
    var rates: array[AchievementCount, int]
    for i in 0 ..< 50:
      var unlocked = newJArray()
      for a in Achievement:
        ## Achievement k unlocks in exactly (k + 1) * 2 % of episodes.
        let on = i * 100 < 50 * (ord(a) + 1) * 2
        if on: inc rates[ord(a)]
        unlocked.add(%on)
      writeFile(dir / ("results-" & $i & ".json"),
        $(%*{"achievementIds": achievementIds(),
             "achievementUnlocked": unlocked}))
    let run = execCmdEx("python3 " & repoRoot() / "tools/crafter_score.py " & dir)
    check run.exitCode == 0
    let report = parseJson(run.output)
    var total = 0.0
    for a in Achievement:
      total += ln(1.0 + 100.0 * float(rates[ord(a)]) / 50.0)
    let reference = exp(total / float(AchievementCount)) - 1.0
    check abs(report["score"].getFloat() - reference) < 1e-9
    check report["episodes"].getInt() == 50
    ## Zero when nothing ever unlocks, 100 when everything always does.
    removeDir(dir)
    createDir(dir)
    for (name, on, want) in [("never", false, 0.0), ("always", true, 100.0)]:
      removeDir(dir)
      createDir(dir)
      for i in 0 ..< 12:
        var unlocked = newJArray()
        for a in Achievement:
          unlocked.add(%on)
        writeFile(dir / ("r" & $i & ".json"),
          $(%*{"achievementIds": achievementIds(),
               "achievementUnlocked": unlocked}))
      let one = execCmdEx("python3 " & repoRoot() / "tools/crafter_score.py " & dir)
      check one.exitCode == 0
      check abs(parseJson(one.output)["score"].getFloat() - want) < 1e-9
      discard name
    removeDir(dir)

  test "the tick budget: a saturated longnight episode in under two seconds":
    ## Item 18.
    var config = testConfig("longnight")
    config.maxCows = 12
    config.maxZombies = 12
    config.maxSkeletons = 6
    let started = cpuTime()
    var sim = startedSim(config)
    while sim.phase == Playing:
      sim.runTurn(@[Action(kind: akDo, n: 24)])
      if sim.runTick() >= config.maxTicks:
        break
    let elapsed = cpuTime() - started
    when defined(release):
      check elapsed < 2.0
    check sim.runTick() > 0
