## The 64 x 64 integer cell grid: the seeded integer value-noise generator and
## its five-step playability post-pass, the glyph/walkable tables, the 9 x 9
## egocentric window, the 16 x 16 region downsample, and the BFS that `goto`
## and `forager` share.
##
## PURE INTEGER. There is no floating point in this module, no pixie, and no
## pixel query — that is what makes the native <-> wasm hash chain exact by
## construction, and `tests/test_crafter_sim.nim` greps for it. The noise is a
## hashed lattice with FIXED-POINT bilinear interpolation, not OpenSimplex,
## because a float noise field cannot be hashed identically native and in
## wasm (§Sim module -> Documented divergences 2).

import sim_types

type
  World* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    cells*: array[WorldCells, Terrain]
    ripenAt*: array[WorldCells, int]
      ## for a `tSapling` cell, the tick it becomes a ripe plant; 0 = never.

  KnownCell* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    seen*: bool
    terrain*: Terrain
    seenTick*: int

  KnownMap* = object
    ## FLATTY WIRE TYPE — field order is sacred. Creatures are NEVER
    ## remembered: they appear only in `view` and in `threats`.
    cells*: array[WorldCells, KnownCell]

proc idx*(x, y: int): int {.inline.} = y * WorldSize + x

proc inBounds*(x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < WorldSize and y < WorldSize

proc chebyshev*(ax, ay, bx, by: int): int {.inline.} =
  max(abs(ax - bx), abs(ay - by))

proc manhattan*(ax, ay, bx, by: int): int {.inline.} =
  abs(ax - bx) + abs(ay - by)

proc at*(world: World, x, y: int): Terrain =
  if not inBounds(x, y): tBedrock else: world.cells[idx(x, y)]

proc setAt*(world: var World, x, y: int, terrain: Terrain) =
  if inBounds(x, y):
    world.cells[idx(x, y)] = terrain

# ---------------------------------------------------------------------------
#  The four integer value-noise fields
# ---------------------------------------------------------------------------

proc lattice(seed, salt, gx, gy: int): int {.inline.} =
  ## One lattice corner value in 0..1023, a pure read of `mix64`.
  int(mix64(seed, salt, gx, gy) mod 1024'u64)

proc noiseAt*(seed, salt, x, y: int): int =
  ## Bilinear interpolation of the stride-8 lattice in 16-bit FIXED POINT.
  ## Result is an integer 0..1023. No floating point anywhere.
  let
    gx = x div NoiseStride
    gy = y div NoiseStride
    fx = (x mod NoiseStride) * 65536 div NoiseStride
    fy = (y mod NoiseStride) * 65536 div NoiseStride
    c00 = lattice(seed, salt, gx, gy)
    c10 = lattice(seed, salt, gx + 1, gy)
    c01 = lattice(seed, salt, gx, gy + 1)
    c11 = lattice(seed, salt, gx + 1, gy + 1)
    top = c00 * (65536 - fx) + c10 * fx
    bottom = c01 * (65536 - fx) + c11 * fx
  ((top div 65536) * (65536 - fy) + (bottom div 65536) * fy) div 65536

const
  SaltMountain* = 1
  SaltWater* = 2
  SaltTree* = 3
  SaltCave* = 4

proc fieldsAt*(seed, x, y: int): tuple[m, w, t, c: int] =
  (noiseAt(seed, SaltMountain, x, y),
   noiseAt(seed, SaltWater, x, y),
   noiseAt(seed, SaltTree, x, y),
   noiseAt(seed, SaltCave, x, y))

proc baseTerrain*(seed, mountainThreshold, x, y: int): Terrain =
  ## The generator's first-match-wins ladder for one interior cell.
  let f = fieldsAt(seed, x, y)
  if f.m > mountainThreshold:
    if f.c > 830 and f.m < 850: tPath
    elif f.c < 60 and f.m > 780: tLava
    elif f.m > 960 and f.c > 900 and int(mix64(seed, 13, x, y) mod 1000'u64) < 60:
      tDiamond
    elif f.m > 800 and int(mix64(seed, 12, x, y) mod 1000'u64) < 8: tIron
    elif f.m > 760 and int(mix64(seed, 11, x, y) mod 1000'u64) < 12: tCoal
    else: tStone
  elif f.w > 640: tWater
  elif f.w > 590: tSand
  elif f.t > 700: tTree
  else: tGrass

const
  SpawnX* = WorldSize div 2      ## 32
  SpawnY* = WorldSize div 2      ## 32

proc firstGrassAtRing(world: World, distance: int): tuple[ok: bool, x, y: int] =
  ## The first `grass` cell (ascending (y, x)) at exactly Chebyshev
  ## `distance` from spawn.
  for y in 0 ..< WorldSize:
    for x in 0 ..< WorldSize:
      if chebyshev(x, y, SpawnX, SpawnY) != distance:
        continue
      if world.cells[idx(x, y)] == tGrass:
        return (true, x, y)
  (false, 0, 0)

proc withinRadius(world: World, terrain: Terrain, radius: int): bool =
  for y in max(0, SpawnY - radius) .. min(WorldSize - 1, SpawnY + radius):
    for x in max(0, SpawnX - radius) .. min(WorldSize - 1, SpawnX + radius):
      if world.cells[idx(x, y)] == terrain:
        return true
  false

proc countOf(world: World, terrain: Terrain): int =
  for cell in world.cells:
    if cell == terrain: inc result

proc highestStone(world: World, seed: int): int =
  ## The `stone` cell with the highest mountain field; ties by ascending
  ## (y, x). -1 when there is no stone left at all.
  result = -1
  var best = -1
  for y in 0 ..< WorldSize:
    for x in 0 ..< WorldSize:
      if world.cells[idx(x, y)] != tStone:
        continue
      let m = noiseAt(seed, SaltMountain, x, y)
      if m > best:
        best = m
        result = idx(x, y)

proc generate*(seed, mountainThreshold: int): World =
  ## The world is a PURE FUNCTION of (seed, variant). Nothing the policy does
  ## can shift a draw, reorder draws or consume one out from under a later
  ## tick, which is the strongest form of the idea's "seeded worlds".
  for y in 0 ..< WorldSize:
    for x in 0 ..< WorldSize:
      result.cells[idx(x, y)] =
        if x == 0 or y == 0 or x == WorldSize - 1 or y == WorldSize - 1:
          tBedrock
        else:
          baseTerrain(seed, mountainThreshold, x, y)

  ## The playability post-pass, deterministic and in this order. Without it a
  ## seed can be unwinnable, and an unwinnable seed makes a benchmark
  ## meaningless.
  # 1. The 3 x 3 block centred on spawn is forced to grass.
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      result.setAt(SpawnX + dx, SpawnY + dy, tGrass)
  # 2..4. A tree within 12, water within 12, stone within 20.
  if not result.withinRadius(tTree, 12):
    let spot = result.firstGrassAtRing(6)
    if spot.ok: result.setAt(spot.x, spot.y, tTree)
  if not result.withinRadius(tWater, 12):
    let spot = result.firstGrassAtRing(8)
    if spot.ok: result.setAt(spot.x, spot.y, tWater)
  if not result.withinRadius(tStone, 20):
    let spot = result.firstGrassAtRing(14)
    if spot.ok: result.setAt(spot.x, spot.y, tStone)
  # 5. Global minima, coal first, then iron, then diamond.
  for (terrain, minimum) in [(tCoal, 5), (tIron, 3), (tDiamond, 1)]:
    while result.countOf(terrain) < minimum:
      let slot = result.highestStone(seed)
      if slot < 0:
        break
      result.cells[slot] = terrain

proc terrainDigest*(world: World): uint64 =
  ## The rolling terrain digest folded once at generation. `sim_state.nim`
  ## then maintains it INCREMENTALLY on every terrain mutation rather than
  ## scanning 4096 cells a tick; `tests/test_crafter_replay.nim` asserts the
  ## incremental value equals this fold after a full episode.
  result = 0xCBF29CE484222325'u64
  for slot in 0 ..< WorldCells:
    result = result xor cast[uint64](int64(ord(world.cells[slot]) + 1))
    result = result * 0x100000001B3'u64
    result = result xor (result shr 29)

proc mixTerrain*(digest: uint64, x, y: int, oldKind, newKind: Terrain): uint64 =
  ## `terrainHash = mixHash(terrainHash, x, y, oldKind, newKind)`.
  result = digest
  for value in [x, y, ord(oldKind), ord(newKind)]:
    result = result xor cast[uint64](int64(value) + 1)
    result = result * 0x100000001B3'u64
    result = result xor (result shr 29)

# ---------------------------------------------------------------------------
#  Visibility — the exact 9 x 9 rule
# ---------------------------------------------------------------------------
#  There is NO OCCLUSION. Everything in the 9 x 9 box is visible, night or
#  day. Crafter has no line of sight either, and it is what keeps the sim
#  integer, fast and hash-stable.

proc viewOrigin*(ax, ay: int): tuple[x, y: int] =
  (ax - ViewSize div 2, ay - ViewSize div 2)

proc known*(map: KnownMap, x, y: int): KnownCell =
  if not inBounds(x, y):
    return KnownCell(seen: true, terrain: tBedrock)
  map.cells[idx(x, y)]

proc knownGlyph*(map: KnownMap, x, y: int): char =
  let entry = map.known(x, y)
  if not entry.seen: UnseenGlyph else: entry.terrain.glyphOf()

proc mergeVisible*(map: var KnownMap, world: World, ax, ay, tick: int): int =
  ## Tick step 10: mark the 9 x 9 window centred on the cog as seen and merge
  ## it into the known map. Returns how many cells were seen for the FIRST
  ## time, which is what `results.cellsSeen` counts.
  let origin = viewOrigin(ax, ay)
  for j in 0 ..< ViewSize:
    for i in 0 ..< ViewSize:
      let
        x = origin.x + i
        y = origin.y + j
      if not inBounds(x, y):
        continue
      let slot = idx(x, y)
      if not map.cells[slot].seen:
        inc result
      map.cells[slot].seen = true
      map.cells[slot].terrain = world.cells[slot]
      map.cells[slot].seenTick = tick

proc cellsSeen*(map: KnownMap): int =
  for entry in map.cells:
    if entry.seen: inc result

proc regionRows*(map: KnownMap): seq[string] =
  ## Sixteen strings of sixteen glyphs: each region shows the single most
  ## NOTABLE terrain it is known to contain, by the exact priority order. A
  ## region with no observed cell is `?`.
  for ry in 0 ..< RegionSize:
    var row = newString(RegionSize)
    for rx in 0 ..< RegionSize:
      var best = UnseenGlyph
      var bestRank = RegionPriority.len + 1
      for dy in 0 ..< RegionScale:
        for dx in 0 ..< RegionScale:
          let entry = map.cells[idx(rx * RegionScale + dx, ry * RegionScale + dy)]
          if not entry.seen:
            continue
          var rank = RegionPriority.len      ## bedrock and anything unlisted
          for position, terrain in RegionPriority:
            if terrain == entry.terrain:
              rank = position
              break
          if rank < bestRank:
            bestRank = rank
            best = entry.terrain.glyphOf()
      row[rx] = best
    result.add(row)

# ---------------------------------------------------------------------------
#  The goto BFS, run against the known map as of turn start
# ---------------------------------------------------------------------------

proc traversable*(map: KnownMap, x, y: int): bool =
  ## A cell is traversable iff its KNOWN terrain is grass, sand or path. `?`,
  ## water, lava, stone, tree, coal, iron, diamond, bedrock, table, furnace,
  ## sapling and ripe plant are NOT — in particular the driver never routes
  ## through lava and never routes through the unknown.
  if not inBounds(x, y):
    return false
  let entry = map.known(x, y)
  entry.seen and entry.terrain in {tGrass, tSand, tPath}

type BfsResult* = object
  reached*: array[WorldCells, bool]
  parent*: array[WorldCells, int32]
  dist*: array[WorldCells, int32]

proc bfs*(map: KnownMap, sx, sy: int, blocked: openArray[int] = []): BfsResult =
  ## Breadth-first from the cog's cell; edges are 4-adjacency in the fixed
  ## order up, right, down, left, so the path is UNIQUE for a given known map.
  ## `blocked` carries the cells of currently-known hostiles.
  for i in 0 ..< WorldCells:
    result.parent[i] = -1
    result.dist[i] = -1
  if not inBounds(sx, sy):
    return
  var wall: array[WorldCells, bool]
  for slot in blocked:
    if slot >= 0 and slot < WorldCells:
      wall[slot] = true
  var queue = newSeqOfCap[int](WorldCells)
  queue.add(idx(sx, sy))
  result.reached[idx(sx, sy)] = true
  result.dist[idx(sx, sy)] = 0
  var head = 0
  while head < queue.len:
    let
      current = queue[head]
      cx = current mod WorldSize
      cy = current div WorldSize
    inc head
    for dir in Facings:
      let
        nx = cx + FacingDx[dir]
        ny = cy + FacingDy[dir]
      if not inBounds(nx, ny):
        continue
      let slot = idx(nx, ny)
      if result.reached[slot] or wall[slot] or not map.traversable(nx, ny):
        continue
      result.reached[slot] = true
      result.parent[slot] = int32(current)
      result.dist[slot] = result.dist[current] + 1
      queue.add(slot)

proc pathTo*(search: BfsResult, tx, ty: int): seq[int] =
  ## The cell chain from (exclusive) the start to (inclusive) the target, or
  ## an empty seq when the target was never reached.
  if not inBounds(tx, ty) or not search.reached[idx(tx, ty)]:
    return @[]
  var current = idx(tx, ty)
  while search.parent[current] >= 0:
    result.add(current)
    current = int(search.parent[current])
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.len - 1 - i])

proc facingToward*(fromX, fromY, toX, toY: int): tuple[ok: bool, dir: Facing] =
  for dir in Facings:
    if fromX + FacingDx[dir] == toX and fromY + FacingDy[dir] == toY:
      return (true, dir)
  (false, fUp)

proc moveOf*(dir: Facing): Primitive =
  case dir
  of fUp: pMoveUp
  of fRight: pMoveRight
  of fDown: pMoveDown
  of fLeft: pMoveLeft

proc frontierScore*(map: KnownMap, x, y: int): int =
  ## How many of a cell's four neighbours are still `?`. A cell that touches
  ## `?` is where new information is.
  for dir in Facings:
    let
      nx = x + FacingDx[dir]
      ny = y + FacingDy[dir]
    if inBounds(nx, ny) and not map.known(nx, ny).seen:
      inc result
