## Creatures: the stable ordering, the bounded spawn attempts of tick step 6,
## the movement and attack rules of tick step 7, arrow flight, and the dawn
## burn.
##
## Three creature kinds live in a single stable array ordered by
## `(spawnTick, spawnY, spawnX)` — an append-only list whose order is the
## RESOLUTION ORDER and never changes for a living creature. Every draw is a
## pure read of `mix64`, so nothing the policy does can shift one.

import sim_types, world, agent

type
  CreatureStep* = object
    hurt*: bool
    amount*: int
    by*: CreatureKind
    x*, y*: int

  Herd* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    list*: seq[Creature]

proc spec*(kind: CreatureKind): tuple[hp, period: int] =
  case kind
  of ckCow: (3, 4)
  of ckZombie: (5, 2)
  of ckSkeleton: (3, 3)
  of ckArrow: (1, 1)

proc creatureAt*(herd: Herd, x, y: int): int =
  ## The index of the living creature on a cell, or -1.
  result = -1
  for i, creature in herd.list:
    if creature.alive and creature.x == x and creature.y == y:
      return i

proc hostileAt*(herd: Herd, x, y: int): bool =
  let i = herd.creatureAt(x, y)
  i >= 0 and herd.list[i].kind in {ckZombie, ckSkeleton}

proc countOf*(herd: Herd, kind: CreatureKind): int =
  for creature in herd.list:
    if creature.alive and creature.kind == kind: inc result

proc compact*(herd: var Herd) =
  ## Dead creatures leave the list. Order among the living is preserved, so
  ## the resolution order never changes for a living creature.
  var kept: seq[Creature]
  for creature in herd.list:
    if creature.alive: kept.add(creature)
  herd.list = kept

proc isDay*(tick, dayLength, dayFraction: int): bool =
  dayLength > 0 and tick mod dayLength < dayFraction

proc dayNumber*(tick, dayLength: int): int =
  if dayLength <= 0: 1 else: tick div dayLength + 1

proc spawnTerrainOk(kind: CreatureKind, terrain: Terrain): bool =
  case kind
  of ckCow: terrain == tGrass
  of ckZombie: terrain in {tGrass, tSand}
  of ckSkeleton: terrain == tPath
  of ckArrow: false

proc trySpawn*(herd: var Herd, w: World, kind: CreatureKind, cap: int,
               seed, tick, cogX, cogY: int): bool =
  ## ONE attempt per kind per tick, never a retry loop — bounded work per
  ## tick, by construction. Spawns iff the cell has the right terrain, holds
  ## no creature, and its Chebyshev distance to the cog is >= 6, so nothing
  ## ever pops into the 9 x 9 view.
  if cap <= 0 or herd.countOf(kind) >= cap:
    return false
  let
    k = ord(kind)
    cx = int(mix64(seed, 400 + k, tick) mod 62'u64) + 1
    cy = int(mix64(seed, 410 + k, tick) mod 62'u64) + 1
  if not spawnTerrainOk(kind, w.at(cx, cy)):
    return false
  if herd.creatureAt(cx, cy) >= 0:
    return false
  if chebyshev(cx, cy, cogX, cogY) < 6:
    return false
  if cx == cogX and cy == cogY:
    return false
  herd.list.add(Creature(kind: kind, x: cx, y: cy, hp: spec(kind).hp,
                         facing: fDown, lastAct: -99, alive: true))
  true

proc burnAtDawn*(herd: var Herd, w: World): int =
  ## On the first tick of each day, every zombie whose cell is not `path` is
  ## removed. That is what makes night, and only night, dangerous.
  for creature in herd.list.mitems:
    if creature.alive and creature.kind == ckZombie and
        w.at(creature.x, creature.y) != tPath:
      creature.alive = false
      inc result

proc stepToward(fromX, fromY, toX, toY: int): Facing =
  ## Greedy: the larger axis gap first, ties to the vertical.
  if abs(toX - fromX) > abs(toY - fromY):
    if toX > fromX: fRight else: fLeft
  else:
    if toY > fromY: fDown else: fUp

proc clearLine(w: World, ax, ay, bx, by: int): bool =
  ## Every cell strictly between two same-row/column cells is walkable.
  if ax == bx:
    let step = if by > ay: 1 else: -1
    var y = ay + step
    while y != by:
      if not w.at(ax, y).walkable():
        return false
      y += step
    return true
  if ay == by:
    let step = if bx > ax: 1 else: -1
    var x = ax + step
    while x != bx:
      if not w.at(x, ay).walkable():
        return false
      x += step
    return true
  false

proc stepCreatures*(herd: var Herd, w: World, cog: var Cog, seed, tick: int):
    seq[CreatureStep] =
  ## Tick step 7. Creatures act in the stable creature order: arrows move
  ## first, then skeletons, then zombies, then cows. Each applies its damage
  ## to the cog IMMEDIATELY.
  var spawnedArrows: seq[Creature]
  for pass in [ckArrow, ckSkeleton, ckZombie, ckCow]:
    for i in 0 ..< herd.list.len:
      if not herd.list[i].alive or herd.list[i].kind != pass:
        continue
      case pass
      of ckArrow:
        let
          dir = herd.list[i].facing
          nx = herd.list[i].x + FacingDx[dir]
          ny = herd.list[i].y + FacingDy[dir]
        if nx == cog.x and ny == cog.y:
          herd.list[i].alive = false
          cog.vitals[vHealth] = max(0, cog.vitals[vHealth] - 2)
          result.add(CreatureStep(hurt: true, amount: 2, by: ckArrow,
                                  x: nx, y: ny))
          continue
        if not w.at(nx, ny).walkable() or herd.creatureAt(nx, ny) >= 0:
          herd.list[i].alive = false
          continue
        herd.list[i].x = nx
        herd.list[i].y = ny
      of ckSkeleton:
        ## Shooting first: within 6 on the same row or column, a clear line
        ## between, and `tick - lastShot >= 8`.
        if chebyshev(herd.list[i].x, herd.list[i].y, cog.x, cog.y) <= 6 and
            (herd.list[i].x == cog.x or herd.list[i].y == cog.y) and
            tick - herd.list[i].lastAct >= 8 and
            w.clearLine(herd.list[i].x, herd.list[i].y, cog.x, cog.y):
          let dir = stepToward(herd.list[i].x, herd.list[i].y, cog.x, cog.y)
          let
            ax = herd.list[i].x + FacingDx[dir]
            ay = herd.list[i].y + FacingDy[dir]
          herd.list[i].lastAct = tick
          if ax == cog.x and ay == cog.y:
            cog.vitals[vHealth] = max(0, cog.vitals[vHealth] - 2)
            result.add(CreatureStep(hurt: true, amount: 2, by: ckArrow,
                                    x: ax, y: ay))
          elif w.at(ax, ay).walkable() and herd.creatureAt(ax, ay) < 0:
            spawnedArrows.add(Creature(kind: ckArrow, x: ax, y: ay, hp: 1,
                                       facing: dir, lastAct: tick, alive: true))
          continue
        if tick mod spec(ckSkeleton).period != 0:
          continue
        let dir = stepToward(herd.list[i].x, herd.list[i].y, cog.x, cog.y)
        let
          nx = herd.list[i].x + FacingDx[dir]
          ny = herd.list[i].y + FacingDy[dir]
        ## Skeletons move ONLY onto `path`.
        if w.at(nx, ny) == tPath and herd.creatureAt(nx, ny) < 0 and
            not (nx == cog.x and ny == cog.y):
          herd.list[i].x = nx
          herd.list[i].y = ny
      of ckZombie:
        ## Attack from a 4-adjacent cell, at most once per 5 ticks.
        if manhattan(herd.list[i].x, herd.list[i].y, cog.x, cog.y) == 1 and
            tick - herd.list[i].lastAct >= 5:
          herd.list[i].lastAct = tick
          let amount = if cog.asleep: 5 else: 2
          cog.vitals[vHealth] = max(0, cog.vitals[vHealth] - amount)
          result.add(CreatureStep(hurt: true, amount: amount, by: ckZombie,
                                  x: herd.list[i].x, y: herd.list[i].y))
          continue
        if tick mod spec(ckZombie).period != 0:
          continue
        let dir = stepToward(herd.list[i].x, herd.list[i].y, cog.x, cog.y)
        let
          nx = herd.list[i].x + FacingDx[dir]
          ny = herd.list[i].y + FacingDy[dir]
        if w.at(nx, ny).walkable() and w.at(nx, ny) != tLava and
            herd.creatureAt(nx, ny) < 0 and not (nx == cog.x and ny == cog.y):
          herd.list[i].x = nx
          herd.list[i].y = ny
      of ckCow:
        if tick mod spec(ckCow).period != 0:
          continue
        let dir = Facings[int(mix64(seed, 700, i, tick) mod 4'u64)]
        let
          nx = herd.list[i].x + FacingDx[dir]
          ny = herd.list[i].y + FacingDy[dir]
        if w.at(nx, ny).walkable() and w.at(nx, ny) != tLava and
            herd.creatureAt(nx, ny) < 0 and not (nx == cog.x and ny == cog.y):
          herd.list[i].x = nx
          herd.list[i].y = ny
  for arrow in spawnedArrows:
    herd.list.add(arrow)

proc damageCauseOf*(kind: CreatureKind): DeathCause =
  case kind
  of ckZombie: dcZombie
  of ckSkeleton: dcSkeleton
  of ckArrow: dcArrow
  of ckCow: dcNone
