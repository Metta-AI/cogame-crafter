## The two published scripted baselines.
##
## Both emit the SAME reply object an LLM does, through the SAME validator,
## which is what makes the bounded-orders test meaningful. NEITHER EVER EMITS
## `say` OR `notes` — a baseline that narrated would make the feed lie about
## which seats are LLMs.
##
## `forager` is load-bearing in three places: it is the certification player,
## the per-turn fallback when a seat's LLM call fails twice, and the default
## for a seat that registers with neither PLAYER_PROMPT nor PLAYER_SCRIPTED.

import std/strutils
import sim_types, sim_config, world, agent, creatures, achievements, sim_state,
  driver, directives

type
  Baseline* = enum
    blForager = "forager"
    blWanderer = "wanderer"

  BaselineParams* = object
    ## The tunables of the two baselines. They are a parameter object rather
    ## than literals because they were CHOSEN by a grid sweep, not guessed:
    ## `tools/tune_baselines.nim` plays episodes over a bounded matrix of them
    ## and prints the table, `tools/ci/baseline_tuning.json` records the
    ## sweep's pick, and `tests/test_crafter_driver.nim` asserts the shipped
    ## defaults below still equal it.
    thirstThreshold*: int      ## drink <= this triggers the water rule
    hungerThreshold*: int      ## food <= this triggers the food rule
    shelterStones*: int        ## how many neighbours the night rule seals
    sleepTicks*: int           ## the `sleep` n the night rule emits
    restThreshold*: int        ## energy <= this at night triggers the rest rule
    exploreSteps*: int         ## `move` n that crosses into the unknown
    tieBreakByDistance*: bool  ## frontier ties: by BFS distance, else (y, x)

const DefaultBaselineParams* = BaselineParams(
  ## THE GRID HARNESS'S PICK, NOT A GUESS. `tools/tune_baselines.nim` plays
  ## both variants over 40 seeds for every cell of the matrix and this one
  ## wins; `tools/ci/baseline_tuning.json` records the whole grid.
  thirstThreshold: 3,
  hungerThreshold: 3,
  shelterStones: 4,
  sleepTicks: 8,
  restThreshold: 5,
  exploreSteps: 2,
  tieBreakByDistance: false
)

const
  Standable = {tGrass, tSand, tPath}
    ## Walkable AND not fatal. `Terrain.walkable()` includes lava by design —
    ## stepping in is how a cog dies, not something the physics prevents — so
    ## no baseline may ever use it to choose a step.
  Buildable = {tGrass, tSand, tPath}
  Placeable = {tGrass, tSand, tPath, tWater, tLava}

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `forager`: a seat that
  ## says nothing useful still plays the published default rather than sitting
  ## out.
  case text.strip().toLowerAscii()
  of "wanderer", "wander": blWanderer
  else: blForager

proc nearestThreat(sim: SimServer, kinds: set[CreatureKind]):
    tuple[found: bool; x, y, d: int] =
  var best = -1
  for creature in sim.herd.list:
    if not creature.alive or creature.kind notin kinds:
      continue
    let d = chebyshev(creature.x, creature.y, sim.cog.x, sim.cog.y)
    if d > ViewSize div 2:
      continue
    if best < 0 or d < best:
      best = d
      result = (true, creature.x, creature.y, d)

proc frontierCell(sim: SimServer,
                  params: BaselineParams): tuple[found: bool, x, y: int] =
  ## The traversable known cell 4-adjacent to the most `?` cells; ties broken
  ## by lowest BFS distance, then by lowest (y, x).
  let search = sim.knownMap.bfs(sim.cog.x, sim.cog.y)
  var
    best = -1
    bestDist = 0
  for slot in 0 ..< WorldCells:
    let
      x = slot mod WorldSize
      y = slot div WorldSize
    if not search.reached[slot] or not sim.knownMap.traversable(x, y):
      continue
    let unknown = sim.knownMap.frontierScore(x, y)
    if unknown == 0:
      continue
    let distance = int(search.dist[slot])
    let value = unknown - (if params.tieBreakByDistance: distance else: 0)
    if value > best or (value == best and params.tieBreakByDistance and
        distance < bestDist):
      best = value
      bestDist = distance
      result = (true, x, y)

proc outwardFacing(sim: SimServer, x, y: int): Facing =
  ## The neighbour direction of the frontier cell that faces the most `?`.
  ## A direction whose cell is KNOWN LAVA is never chosen: `move` walks into a
  ## walkable cell and lava is walkable, so exploring toward one is suicide.
  result = sim.cog.facing
  var best = -1
  for dir in Facings:
    let
      nx = x + FacingDx[dir]
      ny = y + FacingDy[dir]
    if not inBounds(nx, ny):
      continue
    let entry = sim.knownMap.known(nx, ny)
    if entry.seen and entry.terrain == tLava:
      continue
    let score = (if entry.seen: 0 else: 2) + sim.knownMap.frontierScore(nx, ny)
    if score > best:
      best = score
      result = dir
  ## If every neighbour is known lava, stand still rather than walk into one.
  let
    fx = x + FacingDx[result]
    fy = y + FacingDy[result]
  let chosen = sim.knownMap.known(fx, fy)
  if chosen.seen and chosen.terrain == tLava:
    for dir in Facings:
      let entry = sim.knownMap.known(x + FacingDx[dir], y + FacingDy[dir])
      if not (entry.seen and entry.terrain == tLava):
        return dir

proc knownAt(sim: SimServer, terrain: Terrain): tuple[found: bool; x, y: int] =
  let spot = sim.nearestKnown(terrain)
  (spot.found, spot.x, spot.y)

proc addGoto(directive: var Directive, x, y: int) =
  directive.actions.add(Action(kind: akGoto, x: x, y: y, n: 1))

proc addPrimitive(directive: var Directive, kind: ActionKind, n = 1) =
  directive.actions.add(Action(kind: kind, n: n))

proc placePrefix(sim: SimServer, ok: set[Terrain]): tuple[found: bool,
                                                          moves: seq[Action]] =
  ## The moves that leave the cog FACING a cell it may place into. A
  ## `move_<dir>` steps INTO a walkable cell, and every buildable terrain is
  ## walkable, so "turn to face a grass cell" is not expressible: the cog must
  ## step onto one buildable cell and place into the next. If the faced cell
  ## already qualifies, no move is needed at all.
  let front = sim.cog.ahead()
  if sim.world.at(front.x, front.y) in ok and
      sim.herd.creatureAt(front.x, front.y) < 0:
    return (true, @[])
  for dir in Facings:
    let
      ax = sim.cog.x + FacingDx[dir]
      ay = sim.cog.y + FacingDy[dir]
      bx = ax + FacingDx[dir]
      by = ay + FacingDy[dir]
    ## The cell the cog STEPS ONTO must be plain ground: `move` walks into a
    ## walkable cell and lava is walkable, so a step onto it is a death.
    ## Only the cell it ends up FACING may be water or lava.
    if sim.world.at(ax, ay) in Standable and sim.world.at(bx, by) in ok and
        sim.herd.creatureAt(ax, ay) < 0 and sim.herd.creatureAt(bx, by) < 0:
      return (true, @[Action(kind: akMove, dir: dir, n: 1)])
  (false, @[])

proc foragerPlan*(sim: SimServer, params = DefaultBaselineParams): Directive =
  ## THE deterministic priority ladder. Every turn the FIRST matching rule
  ## wins and emits at most `maxActionsPerTurn` actions. `forager` never
  ## routes through lava (lava is not traversable to the BFS) and never sleeps
  ## with an open neighbour it can afford to seal.
  result.source = dsScripted
  let cap = max(1, sim.config.maxActionsPerTurn)
  let front = sim.cog.ahead()

  template finishTurn(pad: bool): untyped =
    ## A plan that expands to three primitives spends a whole TURN on three
    ## ticks, and the turn cap — not the tick cap — is then what ends the
    ## episode. Every rule that is not a fight or a night in a sealed hole
    ## therefore pads its plan with the explore tail, so a `forager` episode
    ## fills its 24-tick turns and the replay is long enough for the viewer
    ## soak to observe real advancement (the ecos 2026-08-23 scar).
    if pad and result.actions.len < cap:
      let tail = sim.frontierCell(params)
      if tail.found:
        result.addGoto(tail.x, tail.y)
        result.actions.add(Action(kind: akMove,
          dir: sim.outwardFacing(tail.x, tail.y), n: params.exploreSteps))
    if result.actions.len > cap:
      result.actions.setLen(cap)
    return

  # 1. Under attack. A zombie or skeleton within Chebyshev 2.
  let hostile = sim.nearestThreat({ckZombie, ckSkeleton})
  if hostile.found and hostile.d <= 2:
    if front.x == hostile.x and front.y == hostile.y:
      result.addPrimitive(akDo, 3)
      finishTurn(false)
    let toward = facingToward(sim.cog.x, sim.cog.y, hostile.x, hostile.y)
    if toward.ok:
      result.actions.add(Action(kind: akMove, dir: toward.dir, n: 1))
      result.addPrimitive(akDo, 3)
      finishTurn(false)
    ## Back away: walk to the reachable known cell farthest from the hostile.
    let search = sim.knownMap.bfs(sim.cog.x, sim.cog.y, sim.hostileCells())
    var
      bestSlot = -1
      bestScore = -1
    for slot in 0 ..< WorldCells:
      if not search.reached[slot] or int(search.dist[slot]) > 8:
        continue
      let score = chebyshev(slot mod WorldSize, slot div WorldSize,
                            hostile.x, hostile.y)
      if score > bestScore:
        bestScore = score
        bestSlot = slot
    if bestSlot >= 0 and bestScore > hostile.d:
      result.addGoto(bestSlot mod WorldSize, bestSlot div WorldSize)
      finishTurn(false)

  # 2. Thirst.
  if sim.cog.drink() <= params.thirstThreshold:
    let water = sim.knownAt(tWater)
    if water.found:
      result.addGoto(water.x, water.y)
      result.addPrimitive(akDo, max(1, VitalMax - sim.cog.drink()))
      finishTurn(true)

  # 3. Hunger.
  if sim.cog.food() <= params.hungerThreshold:
    let plant = sim.knownAt(tRipePlant)
    if plant.found:
      result.addGoto(plant.x, plant.y)
      result.addPrimitive(akDo, 1)
      finishTurn(true)
    let cow = sim.nearestThreat({ckCow})
    if cow.found:
      result.addGoto(cow.x, cow.y)
      result.addPrimitive(akDo, 4)
      finishTurn(true)

  # 4. Night shelter, and the rest rule that keeps energy off zero.
  if (not sim.isDaylight() and sim.cog.energy() <= params.restThreshold) or
      sim.cog.energy() <= 2:
    ## Seal the side the cog is FACING, then sleep. `move_<dir>` steps INTO a
    ## walkable cell and every open side is walkable, so "turn to face an open
    ## side" is not expressible in the action set: the only side a cog can
    ## wall off without walking out of its own hole is the one it is already
    ## facing. So this is ONE stone per turn, not the note's `min(4, stone)` in
    ## one plan — up to `shelterStones` of them across consecutive turns — and
    ## then it sleeps. Sleeping in the open is how cogs die, and it is also the
    ## only way to reach `wake_up`.
    ## (docs/PORTING-CRAFTER.md §D records this and the rest-rule condition.)
    if params.shelterStones > 0 and sim.cog.inventory[rStone] > 0 and
        sim.world.at(front.x, front.y) in Standable and
        sim.herd.creatureAt(front.x, front.y) < 0:
      result.addPrimitive(akPlaceStone)
    result.addPrimitive(akSleep, params.sleepTicks)
    finishTurn(false)

  # 5. The tech ladder. The first unmet step, exactly the order of the
  #    twenty-two achievements.
  block ladder:
    if sim.cog.inventory[rWood] < 1:
      let tree = sim.knownAt(tTree)
      if tree.found:
        result.addGoto(tree.x, tree.y)
        result.addPrimitive(akDo, 5)
        break ladder

    let nearTable = sim.world.nearTerrain(sim.cog, tTable)
    let nearFurnace = sim.world.nearTerrain(sim.cog, tFurnace)
    let needWoodTools = not sim.cog.tools[toWoodPickaxe] or
                        not sim.cog.tools[toWoodSword]
    if (needWoodTools or not sim.ledger.has(aPlaceTable)) and
        sim.cog.inventory[rWood] >= 1:
      if not nearTable:
        let spot = sim.placePrefix(Buildable)
        if spot.found:
          for move in spot.moves: result.actions.add(move)
          result.addPrimitive(akPlaceTable)
        else:
          let table = sim.knownAt(tTable)
          if table.found:
            result.addGoto(table.x, table.y)
      if not sim.cog.tools[toWoodPickaxe]:
        result.addPrimitive(akMakeWoodPickaxe)
      if not sim.cog.tools[toWoodSword]:
        result.addPrimitive(akMakeWoodSword)
      break ladder

    if sim.cog.tools[toWoodPickaxe] and sim.cog.inventory[rStone] < 1:
      let stone = sim.knownAt(tStone)
      if stone.found:
        result.addGoto(stone.x, stone.y)
        result.addPrimitive(akDo, 3)
        break ladder

    if sim.cog.inventory[rStone] >= 1 and not sim.ledger.has(aPlaceStone):
      let spot = sim.placePrefix(Placeable)
      if spot.found:
        for move in spot.moves: result.actions.add(move)
        result.addPrimitive(akPlaceStone)
        break ladder

    let needStoneTools = not sim.cog.tools[toStonePickaxe] or
                         not sim.cog.tools[toStoneSword]
    if needStoneTools and sim.cog.inventory[rStone] >= 1 and
        sim.cog.inventory[rWood] >= 1:
      if not nearTable:
        if sim.cog.inventory[rWood] >= 2:
          let spot = sim.placePrefix(Buildable)
          if spot.found:
            for move in spot.moves: result.actions.add(move)
            result.addPrimitive(akPlaceTable)
        else:
          let table = sim.knownAt(tTable)
          if table.found:
            result.addGoto(table.x, table.y)
      if not sim.cog.tools[toStonePickaxe]:
        result.addPrimitive(akMakeStonePickaxe)
      if not sim.cog.tools[toStoneSword]:
        result.addPrimitive(akMakeStoneSword)
      break ladder

    if sim.cog.inventory[rStone] >= 1 and not sim.ledger.has(aPlaceFurnace):
      let spot = sim.placePrefix(Buildable)
      if spot.found:
        for move in spot.moves: result.actions.add(move)
        result.addPrimitive(akPlaceFurnace)
        break ladder

    if sim.cog.tools[toWoodPickaxe] and sim.cog.inventory[rCoal] < 1:
      let coal = sim.knownAt(tCoal)
      if coal.found:
        result.addGoto(coal.x, coal.y)
        result.addPrimitive(akDo, 3)
        break ladder

    if sim.cog.tools[toStonePickaxe] and sim.cog.inventory[rIron] < 1:
      let iron = sim.knownAt(tIron)
      if iron.found:
        result.addGoto(iron.x, iron.y)
        result.addPrimitive(akDo, 3)
        break ladder

    let needIronTools = not sim.cog.tools[toIronPickaxe] or
                        not sim.cog.tools[toIronSword]
    if needIronTools and sim.cog.inventory[rIron] >= 1 and
        sim.cog.inventory[rCoal] >= 1 and sim.cog.inventory[rWood] >= 1:
      if not nearTable and sim.cog.inventory[rWood] >= 2:
        let spot = sim.placePrefix(Buildable)
        if spot.found:
          for move in spot.moves: result.actions.add(move)
          result.addPrimitive(akPlaceTable)
      if not nearFurnace and sim.cog.inventory[rStone] >= 1:
        let spot = sim.placePrefix(Buildable)
        if spot.found:
          for move in spot.moves: result.actions.add(move)
          result.addPrimitive(akPlaceFurnace)
      if not sim.cog.tools[toIronPickaxe]:
        result.addPrimitive(akMakeIronPickaxe)
      if not sim.cog.tools[toIronSword]:
        result.addPrimitive(akMakeIronSword)
      break ladder

    if sim.cog.tools[toIronPickaxe] and sim.cog.inventory[rDiamond] < 1:
      let diamond = sim.knownAt(tDiamond)
      if diamond.found:
        result.addGoto(diamond.x, diamond.y)
        result.addPrimitive(akDo, 3)
        break ladder

    ## Topping up: keep wood and stone in hand so the next rung is affordable.
    if sim.cog.inventory[rWood] < 3:
      let tree = sim.knownAt(tTree)
      if tree.found:
        result.addGoto(tree.x, tree.y)
        result.addPrimitive(akDo, 5)
        break ladder
    if sim.cog.tools[toWoodPickaxe] and sim.cog.inventory[rStone] < 3:
      let stone = sim.knownAt(tStone)
      if stone.found:
        result.addGoto(stone.x, stone.y)
        result.addPrimitive(akDo, 3)
        break ladder
  if result.actions.len > 0:
    finishTurn(true)

  # 6. Sapling.
  if sim.cog.inventory[rSapling] >= 1 and not sim.ledger.has(aPlacePlant):
    let spot = sim.placePrefix({tGrass})
    if spot.found:
      for move in spot.moves: result.actions.add(move)
      result.addPrimitive(akPlacePlant)
      finishTurn(true)

  ## Drink and eat opportunistically before exploring: water is free and never
  ## runs out, and a cog at 4 bars is a cog with a bug in its plan.
  if sim.cog.drink() < VitalMax and sim.world.at(front.x, front.y) == tWater:
    result.addPrimitive(akDo, VitalMax - sim.cog.drink())
    finishTurn(true)

  # 7. Explore, and actually cross into the unknown.
  let frontier = sim.frontierCell(params)
  if frontier.found:
    result.addGoto(frontier.x, frontier.y)
    result.actions.add(Action(kind: akMove,
      dir: sim.outwardFacing(frontier.x, frontier.y), n: params.exploreSteps))
    finishTurn(true)

  ## Nothing else to do: use whatever is ahead. A `do` is never illegal.
  result.addPrimitive(akDo, 4)

proc wandererPlan*(sim: SimServer,
                   params = DefaultBaselineParams): Directive =
  ## The reactive control, four lines and no memory: every turn emit twelve
  ## actions alternating `move` and `do`, rotating the facing clockwise
  ## whenever the cell ahead is not traversable in the current view.
  result.source = dsScripted
  var
    x = sim.cog.x
    y = sim.cog.y
    dir = sim.cog.facing
  let cap = max(1, sim.config.maxActionsPerTurn)
  while result.actions.len + 2 <= cap:
    if sim.world.at(x + FacingDx[dir], y + FacingDy[dir]) in Standable:
      ## `n = 2` only when BOTH cells are plain ground: the second step of a
      ## `move` is a real step too, and lava does not stop it.
      let twoSteps = sim.world.at(x + 2 * FacingDx[dir],
                             y + 2 * FacingDy[dir]) in Standable
      result.actions.add(Action(kind: akMove, dir: dir, n: (if twoSteps: 2 else: 1)))
      x = x + FacingDx[dir]
      y = y + FacingDy[dir]
      if twoSteps:
        x = x + FacingDx[dir]
        y = y + FacingDy[dir]
    else:
      ## Rotate clockwise past anything that is not plain ground. A `move`
      ## walks INTO a walkable cell and lava is walkable, so a blind rotation
      ## into it would be the control policy killing itself on tick one.
      var turned = dir
      for step in 1 .. 4:
        turned = Facings[(ord(turned) + 1) mod 4]
        if sim.world.at(x + FacingDx[turned], y + FacingDy[turned]) notin
            {tLava}:
          break
      dir = turned
      result.actions.add(Action(kind: akMove, dir: dir, n: 1))
      if sim.world.at(x + FacingDx[dir], y + FacingDy[dir]) in Standable:
        x = x + FacingDx[dir]
        y = y + FacingDy[dir]
    result.addPrimitive(akDo, 1)

proc scriptedPlan*(sim: SimServer, kind: Baseline,
                   params = DefaultBaselineParams): Directive =
  ## The one entry point. `forager` is imported by the decision engine as its
  ## fallback — never duplicated — so the two cannot drift.
  case kind
  of blForager: foragerPlan(sim, params)
  of blWanderer: wandererPlan(sim, params)
