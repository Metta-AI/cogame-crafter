## The cog record — position, facing, asleep, vitals, inventory, tools — the
## seventeen primitives of tick step 3 with their exact effects, the six
## recipes with their adjacency requirements, and the vitals block of tick
## step 4.
##
## `applyPrimitive` is the WHOLE physics of one cog action. An inapplicable
## primitive is a NO-OP THAT STILL COSTS ITS TICK: there is no error, no
## repair and no free retry, and that is the whole cost model of the game.

import sim_types, world

type
  PrimitiveEffect* = enum
    ## What one primitive did, for the event stream and the achievement
    ## predicates. `peNone` is the honest outcome of a `noop` and of every
    ## inapplicable primitive.
    peNone
    peTurned
    peMoved
    peBlocked
    peCollect          ## a `do` that yielded a resource
    peDrink            ## a `do` on water
    peEatPlant         ## a `do` on a ripe plant
    peAttack           ## a `do` on a creature
    pePlace
    peCraft
    peSleep
    peLava             ## stepped into lava: instant death

  Cog* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    x*, y*: int
    facing*: Facing
    asleep*: bool
    sleepRunStartEnergy*: int   ## energy when the current sleep run began
    sleepRun*: int              ## consecutive `sleep` ticks
    vitals*: array[Vital, int]
    inventory*: array[Resource, int]
    tools*: array[Tool, bool]

  PrimitiveResult* = object
    effect*: PrimitiveEffect
    x*, y*: int                 ## the cell the effect happened on
    resource*: Resource
    gotResource*: bool
    placed*: Terrain
    crafted*: Tool
    damage*: int                ## damage the cog dealt this tick
    amount*: int                ## drink/food delta
    mined*: bool
    wokeRested*: bool           ## a sleep run ended at full energy
    changes*: seq[tuple[x, y: int, terrain: Terrain]]
      ## the terrain mutations this primitive asks for. `applyPrimitive` never
      ## writes the world itself: `sim_state.nim` applies them through the ONE
      ## door that also maintains the incremental terrain digest, so the
      ## digest can never drift from the grid (§Determinism point 4).
    ripen*: seq[tuple[slot, at: int]]

proc newCog*(x, y: int): Cog =
  result.x = x
  result.y = y
  result.facing = fDown
  for vital in Vital:
    result.vitals[vital] = VitalMax

proc ahead*(cog: Cog): tuple[x, y: int] =
  (cog.x + FacingDx[cog.facing], cog.y + FacingDy[cog.facing])

proc health*(cog: Cog): int = cog.vitals[vHealth]
proc food*(cog: Cog): int = cog.vitals[vFood]
proc drink*(cog: Cog): int = cog.vitals[vDrink]
proc energy*(cog: Cog): int = cog.vitals[vEnergy]

proc gain*(cog: var Cog, vital: Vital, amount: int): int =
  ## Adds to a vital, capped at VitalMax; returns what actually landed.
  let before = cog.vitals[vital]
  cog.vitals[vital] = min(VitalMax, before + amount)
  cog.vitals[vital] - before

proc give*(cog: var Cog, resource: Resource, amount = 1) =
  ## A collection that would exceed InventoryMax is capped and STILL unlocks
  ## its achievement.
  cog.inventory[resource] = min(InventoryMax, cog.inventory[resource] + amount)

proc swordDamage*(cog: Cog): int =
  ## 1 bare-handed, 2 with a wood sword, 3 with stone, 5 with iron.
  if cog.tools[toIronSword]: 5
  elif cog.tools[toStoneSword]: 3
  elif cog.tools[toWoodSword]: 2
  else: 1

# ---------------------------------------------------------------------------
#  The six recipes
# ---------------------------------------------------------------------------

type Recipe* = object
  tool*: Tool
  wood*, stone*, coal*, iron*: int
  needsFurnace*: bool

const Recipes*: array[Tool, Recipe] = [
  Recipe(tool: toWoodPickaxe, wood: 1),
  Recipe(tool: toStonePickaxe, wood: 1, stone: 1),
  Recipe(tool: toIronPickaxe, wood: 1, coal: 1, iron: 1, needsFurnace: true),
  Recipe(tool: toWoodSword, wood: 1),
  Recipe(tool: toStoneSword, wood: 1, stone: 1),
  Recipe(tool: toIronSword, wood: 1, coal: 1, iron: 1, needsFurnace: true)
]

proc toolOf*(primitive: Primitive): tuple[ok: bool, tool: Tool] =
  case primitive
  of pMakeWoodPickaxe: (true, toWoodPickaxe)
  of pMakeStonePickaxe: (true, toStonePickaxe)
  of pMakeIronPickaxe: (true, toIronPickaxe)
  of pMakeWoodSword: (true, toWoodSword)
  of pMakeStoneSword: (true, toStoneSword)
  of pMakeIronSword: (true, toIronSword)
  else: (false, toWoodPickaxe)

proc canAfford*(cog: Cog, recipe: Recipe): bool =
  cog.inventory[rWood] >= recipe.wood and
    cog.inventory[rStone] >= recipe.stone and
    cog.inventory[rCoal] >= recipe.coal and
    cog.inventory[rIron] >= recipe.iron

proc pay(cog: var Cog, recipe: Recipe) =
  cog.inventory[rWood] -= recipe.wood
  cog.inventory[rStone] -= recipe.stone
  cog.inventory[rCoal] -= recipe.coal
  cog.inventory[rIron] -= recipe.iron

proc nearTerrain*(w: World, cog: Cog, terrain: Terrain): bool =
  ## Within Chebyshev distance 1 of the cog — the crafting adjacency rule.
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if w.at(cog.x + dx, cog.y + dy) == terrain:
        return true
  false

# ---------------------------------------------------------------------------
#  Mining
# ---------------------------------------------------------------------------

proc minedBy*(terrain: Terrain, cog: Cog): bool =
  ## The "Mined by `do`" column, with its tool requirement.
  case terrain
  of tGrass, tWater, tTree, tRipePlant: true
  of tStone, tCoal: cog.tools[toWoodPickaxe]
  of tIron: cog.tools[toStonePickaxe]
  of tDiamond: cog.tools[toIronPickaxe]
  else: false

proc mineYield*(terrain: Terrain): tuple[has: bool, resource: Resource] =
  case terrain
  of tGrass: (true, rSapling)
  of tStone: (true, rStone)
  of tTree: (true, rWood)
  of tCoal: (true, rCoal)
  of tIron: (true, rIron)
  of tDiamond: (true, rDiamond)
  else: (false, rWood)

proc mineBecomes*(terrain: Terrain): Terrain =
  ## Trees are INFINITE and mining stone leaves walkable `path` — Crafter's
  ## semantics, stated because they are the ones an implementer guesses wrong.
  case terrain
  of tStone, tCoal, tIron, tDiamond: tPath
  of tRipePlant: tSapling
  else: terrain

# ---------------------------------------------------------------------------
#  The seventeen primitives — tick step 3
# ---------------------------------------------------------------------------

proc placedBy*(primitive: Primitive): tuple[ok: bool; terrain: Terrain;
                                            cost: Resource] =
  case primitive
  of pPlaceStone: (true, tStone, rStone)
  of pPlaceTable: (true, tTable, rWood)
  of pPlaceFurnace: (true, tFurnace, rStone)
  of pPlacePlant: (true, tSapling, rSapling)
  else: (false, tGrass, rWood)

proc applyPrimitive*(cog: var Cog, w: World, primitive: Primitive,
                     seed, tick, plantRipenTicks: int,
                     creatureAhead: bool): PrimitiveResult =
  ## Tick step 3, exactly. `creatureAhead` is resolved by the caller because
  ## the creature list lives in `creatures.nim`; a `do` facing a creature is
  ## handled there (a creature there is attacked BEFORE the terrain rule).
  let front = cog.ahead()
  result.x = front.x
  result.y = front.y

  ## Any primitive other than `sleep` wakes the cog.
  if primitive != pSleep and cog.asleep:
    cog.asleep = false
    if cog.energy() >= VitalMax and cog.sleepRunStartEnergy < VitalMax:
      result.wokeRested = true
    cog.sleepRun = 0

  let moving = moveFacing(primitive)
  if moving.ok:
    ## `move_<dir>` sets facing AND steps one cell if that cell is walkable
    ## and holds no creature; if it is not, the cog only turns. This is
    ## Crafter's semantics and it is the one an implementer guesses wrong.
    cog.facing = moving.dir
    let
      nx = cog.x + FacingDx[moving.dir]
      ny = cog.y + FacingDy[moving.dir]
    result.x = nx
    result.y = ny
    let target = w.at(nx, ny)
    if target.walkable() and not creatureAhead and inBounds(nx, ny):
      cog.x = nx
      cog.y = ny
      if target == tLava:
        cog.vitals[vHealth] = 0
        result.effect = peLava
      else:
        result.effect = peMoved
    else:
      result.effect = peTurned
    return

  case primitive
  of pNoop:
    result.effect = peNone
  of pDo:
    if creatureAhead:
      result.effect = peAttack
      result.damage = cog.swordDamage()
      return
    let terrain = w.at(front.x, front.y)
    if not terrain.minedBy(cog):
      result.effect = peNone
      return
    case terrain
    of tWater:
      let landed = cog.gain(vDrink, 1)
      result.amount = landed
      result.effect = peDrink
    of tRipePlant:
      result.amount = cog.gain(vFood, 6)
      result.changes.add((front.x, front.y, tSapling))
      result.ripen.add((idx(front.x, front.y), tick + plantRipenTicks))
      result.effect = peEatPlant
    of tGrass:
      ## A `do` on grass yields a sapling iff the 1-in-10 draw lands.
      if int(mix64(seed, 600, idx(front.x, front.y), tick) mod 10'u64) == 0:
        cog.give(rSapling)
        result.gotResource = true
        result.resource = rSapling
        result.effect = peCollect
      else:
        result.effect = peNone
    else:
      let produce = terrain.mineYield()
      if produce.has:
        cog.give(produce.resource)
        result.gotResource = true
        result.resource = produce.resource
        result.mined = true
        result.effect = peCollect
        let becomes = terrain.mineBecomes()
        if becomes != terrain:
          result.changes.add((front.x, front.y, becomes))
      else:
        result.effect = peNone
  of pSleep:
    if not cog.asleep:
      cog.asleep = true
      cog.sleepRunStartEnergy = cog.energy()
      cog.sleepRun = 0
    inc cog.sleepRun
    discard cog.gain(vEnergy, 1)
    result.effect = peSleep
  of pPlaceStone, pPlaceTable, pPlaceFurnace, pPlacePlant:
    let spec = placedBy(primitive)
    let terrain = w.at(front.x, front.y)
    let ok =
      case primitive
      of pPlaceStone: terrain.placeableOver()
      of pPlacePlant: terrain == tGrass
      else: terrain.buildableOver()
    if not ok or creatureAhead or cog.inventory[spec.cost] < 1 or
        not inBounds(front.x, front.y):
      result.effect = peNone
      return
    cog.inventory[spec.cost] -= 1
    result.changes.add((front.x, front.y, spec.terrain))
    if spec.terrain == tSapling:
      result.ripen.add((idx(front.x, front.y), tick + plantRipenTicks))
    result.placed = spec.terrain
    result.effect = pePlace
  else:
    let wanted = toolOf(primitive)
    if not wanted.ok:
      result.effect = peNone
      return
    ## Crafting an already-owned tool is a no-op that costs nothing and still
    ## costs the tick.
    if cog.tools[wanted.tool]:
      result.effect = peNone
      return
    let recipe = Recipes[wanted.tool]
    if not w.nearTerrain(cog, tTable):
      result.effect = peNone
      return
    if recipe.needsFurnace and not w.nearTerrain(cog, tFurnace):
      result.effect = peNone
      return
    if not cog.canAfford(recipe):
      result.effect = peNone
      return
    cog.pay(recipe)
    cog.tools[wanted.tool] = true
    result.crafted = wanted.tool
    result.effect = peCraft

# ---------------------------------------------------------------------------
#  Vitals — tick step 4, the five numbered steps in order
# ---------------------------------------------------------------------------

type VitalsResult* = object
  starved*: array[Vital, bool]   ## which zeroed vital cost health this tick
  regenerated*: bool
  drained*: array[Vital, bool]

proc stepVitals*(cog: var Cog, tick, foodTicks, drinkTicks, energyTicks,
                 regenTicks, starveTicks: int): VitalsResult =
  # 1..3. Drains.
  if foodTicks > 0 and tick mod foodTicks == 0 and cog.vitals[vFood] > 0:
    cog.vitals[vFood] -= 1
    result.drained[vFood] = true
  if drinkTicks > 0 and tick mod drinkTicks == 0 and cog.vitals[vDrink] > 0:
    cog.vitals[vDrink] -= 1
    result.drained[vDrink] = true
  if not cog.asleep and energyTicks > 0 and tick mod energyTicks == 0 and
      cog.vitals[vEnergy] > 0:
    cog.vitals[vEnergy] -= 1
    result.drained[vEnergy] = true
  # 4. Regeneration.
  if cog.food() > 0 and cog.drink() > 0 and cog.energy() > 0 and
      regenTicks > 0 and tick mod regenTicks == 0:
    if cog.gain(vHealth, 1) > 0:
      result.regenerated = true
  # 5. Starvation, food -> drink -> energy. Three zeroed vitals cost 3 health
  #    on the same tick.
  if starveTicks > 0 and tick mod starveTicks == 0:
    for vital in [vFood, vDrink, vEnergy]:
      if cog.vitals[vital] == 0:
        cog.vitals[vHealth] = max(0, cog.vitals[vHealth] - 1)
        result.starved[vital] = true

proc starvationCause*(vital: Vital): DeathCause =
  case vital
  of vFood: dcStarvation
  of vDrink: dcThirst
  of vEnergy: dcExhaustion
  else: dcNone
