## The driver: directive -> per-tick actuation, retargeted from the starter's
## `control.nim` pixel steering to a PRIMITIVE QUEUE.
##
## It is the ONLY producer of primitives and it contains no randomness. It
## never invents an action the schema does not express and it never produces a
## step into a cell it believes is lava — but it makes no promise about a cell
## the cog has never seen, which is why walking into the unknown costs an
## explicit `move`.

import std/strutils
import sim_types, world

type
  ActionKind* = enum
    ## The seventeen primitives by name plus the TWO macros.
    akNoop = "noop"
    akMoveLeft = "move_left"
    akMoveRight = "move_right"
    akMoveUp = "move_up"
    akMoveDown = "move_down"
    akDo = "do"
    akSleep = "sleep"
    akPlaceStone = "place_stone"
    akPlaceTable = "place_table"
    akPlaceFurnace = "place_furnace"
    akPlacePlant = "place_plant"
    akMakeWoodPickaxe = "make_wood_pickaxe"
    akMakeStonePickaxe = "make_stone_pickaxe"
    akMakeIronPickaxe = "make_iron_pickaxe"
    akMakeWoodSword = "make_wood_sword"
    akMakeStoneSword = "make_stone_sword"
    akMakeIronSword = "make_iron_sword"
    akGoto = "goto"
    akMove = "move"

  Action* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    kind*: ActionKind
    x*, y*: int
    dir*: Facing
    n*: int

  Expansion* = object
    primitives*: seq[Primitive]
    truncated*: bool
    unreachable*: int

const
  PrimitiveOf*: array[akNoop .. akMakeIronSword, Primitive] = [
    pNoop, pMoveLeft, pMoveRight, pMoveUp, pMoveDown, pDo, pSleep,
    pPlaceStone, pPlaceTable, pPlaceFurnace, pPlacePlant,
    pMakeWoodPickaxe, pMakeStonePickaxe, pMakeIronPickaxe,
    pMakeWoodSword, pMakeStoneSword, pMakeIronSword]

proc parseActionKind*(text: string): tuple[ok: bool, kind: ActionKind] =
  ## Lower-cased and `-` -> `_` normalised before matching.
  let key = text.strip().toLowerAscii().replace("-", "_")
  for kind in ActionKind:
    if $kind == key:
      return (true, kind)
  (false, akNoop)

proc repeatable*(kind: ActionKind): tuple[ok: bool, limit: int] =
  ## `n` is honoured ONLY on `move` (1..12), `do` (1..12) and `sleep` (1..24),
  ## and is ignored on every other verb.
  case kind
  of akMove, akDo: (true, 12)
  of akSleep: (true, 24)
  else: (false, 1)

proc gotoPrimitives*(map: KnownMap, ax, ay: int, tx, ty: int, cap: int,
                     blocked: openArray[int] = []):
    tuple[ok: bool, primitives: seq[Primitive], x, y: int] =
  ## The `goto` BFS, run against the known map as of TURN START.
  ##
  ## If the target is traversable the path ends ON it. If it is not
  ## traversable but is 4-adjacent to some reached cell, the path ends on the
  ## nearest such cell and a final `move_<dir>` toward the target is appended
  ## — which TURNS the cog to face it without moving (the target is not
  ## walkable), leaving it exactly positioned for `do`. If neither, the macro
  ## yields ZERO primitives and counts as `unreachable`.
  result.x = ax
  result.y = ay
  if not inBounds(tx, ty):
    return
  let search = map.bfs(ax, ay, blocked)
  var
    goalX = tx
    goalY = ty
    faceTarget = false
  if not map.traversable(tx, ty):
    var
      best = -1
      bestSlot = -1
    for adjacent in Facings:
      let
        nx = tx + FacingDx[adjacent]
        ny = ty + FacingDy[adjacent]
      if not inBounds(nx, ny) or not search.reached[idx(nx, ny)]:
        continue
      let distance = int(search.dist[idx(nx, ny)])
      if best < 0 or distance < best or
          (distance == best and idx(nx, ny) < bestSlot):
        best = distance
        bestSlot = idx(nx, ny)
    if bestSlot < 0:
      return
    goalX = bestSlot mod WorldSize
    goalY = bestSlot div WorldSize
    faceTarget = true
  elif not search.reached[idx(tx, ty)]:
    return

  var
    cx = ax
    cy = ay
    primitives: seq[Primitive]
  for slot in search.pathTo(goalX, goalY):
    if primitives.len >= cap:
      break
    let
      nx = slot mod WorldSize
      ny = slot div WorldSize
      toward = facingToward(cx, cy, nx, ny)
    if not toward.ok:
      break
    primitives.add(moveOf(toward.dir))
    cx = nx
    cy = ny
  if faceTarget and primitives.len < cap:
    let toward = facingToward(cx, cy, tx, ty)
    if toward.ok:
      primitives.add(moveOf(toward.dir))
  if primitives.len > cap:
    primitives.setLen(cap)
  result.ok = true
  result.primitives = primitives
  result.x = cx
  result.y = cy

proc expandPlan*(map: KnownMap, ax, ay: int, actions: seq[Action],
                 macroPrimitiveCap, turnTicks: int,
                 blocked: openArray[int] = []): Expansion =
  ## Turn step 5c/5d: macros expand against the known map as of turn start,
  ## then the whole queue is truncated to `turnTicks` primitives. The surplus
  ## is discarded and NOTHING CARRIES OVER to the next turn.
  var
    cx = ax
    cy = ay
  for action in actions:
    case action.kind
    of akGoto:
      let walk = gotoPrimitives(map, cx, cy, action.x, action.y,
                                macroPrimitiveCap, blocked)
      if not walk.ok:
        inc result.unreachable
        continue
      for primitive in walk.primitives:
        result.primitives.add(primitive)
      cx = walk.x
      cy = walk.y
    of akMove:
      let count = min(max(1, action.n), macroPrimitiveCap)
      for i in 0 ..< count:
        result.primitives.add(moveOf(action.dir))
        let
          nx = cx + FacingDx[action.dir]
          ny = cy + FacingDy[action.dir]
        if map.traversable(nx, ny):
          cx = nx
          cy = ny
    else:
      let primitive = PrimitiveOf[action.kind]
      let repeat = repeatable(action.kind)
      let count =
        if repeat.ok: min(max(1, action.n), macroPrimitiveCap) else: 1
      for i in 0 ..< count:
        result.primitives.add(primitive)
      ## Track the virtual pose so a later macro plans from where the earlier
      ## primitives actually left the cog.
      let moving = moveFacing(primitive)
      if moving.ok:
        let
          nx = cx + FacingDx[moving.dir]
          ny = cy + FacingDy[moving.dir]
        if map.traversable(nx, ny):
          cx = nx
          cy = ny
  if result.primitives.len > turnTicks:
    result.primitives.setLen(turnTicks)
    result.truncated = true
