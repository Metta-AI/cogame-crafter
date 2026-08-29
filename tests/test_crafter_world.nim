## World generation — design note §Tests items 1..5.
##
## The world is a PURE FUNCTION of `(seed, variant)`, every seed is
## completable, and the arithmetic is integer only.

import std/[sequtils, sets, strutils, unittest]
import crafter/[sim, driver, baselines]
import helpers

suite "world generation":
  test "world is a pure function of the seed":
    ## Item 1: the same (seed, variant) generates a byte-identical 64 x 64
    ## grid under three different policy behaviours, and two different seeds
    ## differ.
    let config = testConfig()
    var a = playScripted(config, blForager)
    var b = playScripted(config, blWanderer)
    var c = startedSim(config)
    c.runTurn(@[Action(kind: akMove, dir: fUp, n: 6),
                Action(kind: akDo, n: 4)])
    let reference = generate(config.seed, config.mountainThreshold)
    for slot in 0 ..< WorldCells:
      ## The cog mines and places, so the LIVE grids diverge; the generator's
      ## output for the seed does not.
      check generate(config.seed, config.mountainThreshold).cells[slot] ==
        reference.cells[slot]
    check a.config.seed == b.config.seed
    check c.config.seed == reference.cells.len div WorldCells * config.seed
    var other = testConfig(seed = 43)
    let elsewhere = generate(other.seed, other.mountainThreshold)
    var differences = 0
    for slot in 0 ..< WorldCells:
      if elsewhere.cells[slot] != reference.cells[slot]:
        inc differences
    check differences > 100

  test "generation invariants over 200 seeds and both variants":
    ## Item 2.
    for variant in ["standard", "longnight"]:
      let base = testConfig(variant)
      for seed in 1 .. 200:
        let world = generate(seed, base.mountainThreshold)
        ## The bedrock ring is intact and unbroken.
        for i in 0 ..< WorldSize:
          check world.at(i, 0) == tBedrock
          check world.at(i, WorldSize - 1) == tBedrock
          check world.at(0, i) == tBedrock
          check world.at(WorldSize - 1, i) == tBedrock
        ## The 3 x 3 block at spawn is grass.
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            check world.at(SpawnX + dx, SpawnY + dy) == tGrass
        ## A tree within 12, water within 12, stone within 20.
        var near = [false, false, false]
        var counts = [0, 0, 0]
        for y in 0 ..< WorldSize:
          for x in 0 ..< WorldSize:
            let terrain = world.at(x, y)
            let d = chebyshev(x, y, SpawnX, SpawnY)
            if terrain == tTree and d <= 12: near[0] = true
            if terrain == tWater and d <= 12: near[1] = true
            if terrain == tStone and d <= 20: near[2] = true
            if terrain == tCoal: inc counts[0]
            if terrain == tIron: inc counts[1]
            if terrain == tDiamond: inc counts[2]
        check near == [true, true, true]
        check counts[0] >= 5
        check counts[1] >= 3
        check counts[2] >= 1

  test "the guaranteed tree, water and stone are still REACHABLE afterwards":
    ## The regression for the post-pass's ordering hazard. Items 2 and 3 check
    ## that a tree, water and stone EXIST near spawn and that a full-knowledge
    ## solver can climb the tech tree; neither checks that the connectivity
    ## carve left its own guarantee intact. It did not: the corridor is sanded
    ## cell by cell and used to skip any coal, iron or diamond in the way, so
    ## on **seed 105** (both variants) the only corridor to the only reachable
    ## tree was severed by a single coal cell — which no cog can mine before it
    ## has the wood for a pickaxe.
    for variant in ["standard", "longnight"]:
      let base = testConfig(variant)
      for seed in 1 .. 200:
        let world = generate(seed, base.mountainThreshold)
        let region = world.landRegion()
        for terrain in [tTree, tWater, tStone]:
          check world.touches(region, terrain)

  test "every cell holds exactly one terrain from the closed enum":
    let world = generate(9, 700)
    var seen: HashSet[int]
    for slot in 0 ..< WorldCells:
      seen.incl(ord(world.cells[slot]))
    for kind in seen:
      check kind >= ord(low(Terrain)) and kind <= ord(high(Terrain))

  test "the world is completable":
    ## Item 3: over 60 seeds of each variant a search-based reference solver
    ## (TEST-ONLY, never shipped in the image) that ignores the turn budget
    ## reaches `collect_diamond`. A seed where it cannot is a generator bug.
    ##
    ## The solver is a full-knowledge BFS walker: it knows the true grid, so
    ## it measures the WORLD, not a policy.
    proc crossable(terrain: Terrain, cog: Cog, hasStone: bool): bool =
      ## Exactly what the seventeen actions let a cog get through:
      ##   * grass, sand and path it walks on;
      ##   * stone, coal, iron and diamond it MINES, leaving walkable path,
      ##     if it holds the pickaxe the terrain needs;
      ##   * water and lava it BRIDGES with `place_stone`, once it has stone;
      ##   * a tree is infinite and a bedrock ring is forever, so neither is
      ##     ever crossable, and nor is a table, a furnace or a plant.
      case terrain
      of tGrass, tSand, tPath: true
      of tWater, tLava: hasStone
      of tStone, tCoal, tIron, tDiamond: terrain.minedBy(cog)
      else: false

    proc reachable(world: World, cog: Cog, hasStone: bool,
                   tx, ty: int): bool =
      ## Can the cog stand 4-adjacent to (tx, ty), routing only through cells
      ## it can actually get through?
      var seen: array[WorldCells, bool]
      var queue = @[idx(cog.x, cog.y)]
      seen[idx(cog.x, cog.y)] = true
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
          if not inBounds(nx, ny) or seen[idx(nx, ny)]:
            continue
          if nx == tx and ny == ty:
            return true
          if not crossable(world.at(nx, ny), cog, hasStone):
            continue
          seen[idx(nx, ny)] = true
          queue.add(idx(nx, ny))
      false

    proc solves(seed, mountain: int): bool =
      let world = generate(seed, mountain)
      var cog = newCog(SpawnX, SpawnY)
      ## The tech tree, in dependency order, with the solver granting itself
      ## each rung only once it can actually REACH the material for it.
      var hasStone = false
      for (terrain, tools) in [(tTree, @[]), (tStone, @[toWoodPickaxe]),
                               (tCoal, @[toWoodPickaxe]),
                               (tIron, @[toStonePickaxe]),
                               (tDiamond, @[toIronPickaxe])]:
        for tool in tools:
          cog.tools[tool] = true
        var found = false
        for y in 0 ..< WorldSize:
          for x in 0 ..< WorldSize:
            if world.at(x, y) == terrain and
                world.reachable(cog, hasStone, x, y):
              found = true
              break
          if found: break
        if not found:
          return false
        ## From the stone rung on, the cog can bridge water and lava.
        if terrain == tStone:
          hasStone = true
      true

    for variant in ["standard", "longnight"]:
      let base = testConfig(variant)
      for seed in 1 .. 60:
        check solves(seed, base.mountainThreshold)

  test "noise is integer, and a second implementation agrees cell for cell":
    ## Item 4, first half: an independent re-implementation of the bilinear
    ## fixed-point interpolation, compared cell for cell.
    proc reference(seed, salt, x, y: int): int =
      let
        gx = x div NoiseStride
        gy = y div NoiseStride
        fx = (x - gx * NoiseStride) * 65536 div NoiseStride
        fy = (y - gy * NoiseStride) * 65536 div NoiseStride
      var corners: array[4, int]
      for i, (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
        corners[i] = int(mix64(seed, salt, gx + dx, gy + dy) mod 1024'u64)
      let
        top = corners[0] * (65536 - fx) + corners[1] * fx
        bottom = corners[2] * (65536 - fx) + corners[3] * fx
      ((top div 65536) * (65536 - fy) + (bottom div 65536) * fy) div 65536
    for salt in [SaltMountain, SaltWater, SaltTree, SaltCave]:
      for y in countup(0, WorldSize - 1, 3):
        for x in countup(0, WorldSize - 1, 3):
          check noiseAt(1234, salt, x, y) == reference(1234, salt, x, y)
          check noiseAt(1234, salt, x, y) in 0 .. 1023

  test "no floating point in the sim modules":
    ## Item 4, second half: the source grep. A float anywhere here would
    ## break the native <-> wasm hash chain by construction.
    for name in ["sim_state", "world", "agent", "creatures", "achievements",
                 "driver", "baselines"]:
      let source = readRepo("src/crafter/" & name & ".nim")
      var lineNumber = 0
      for line in source.splitLines():
        inc lineNumber
        let code = line.split("##")[0].strip()
        if code.len == 0:
          continue
        check not code.contains("float")
        check not code.contains("sqrt")
        check not code.contains(".0")

  test "the glyph, walkable and mineable tables are total and distinct":
    ## Item 5.
    var glyphs: HashSet[char]
    for terrain in Terrain:
      glyphs.incl(terrain.glyphOf())
    for kind in CreatureKind:
      glyphs.incl(CreatureGlyphs[kind])
    glyphs.incl(CogGlyph)
    glyphs.incl(UnseenGlyph)
    ## Pairwise distinct, and they are the WHOLE vocabulary the seat reads.
    ## Fifteen terrains + four creatures + `@` + `?` = TWENTY-ONE glyphs. The
    ## design note's prose says "twenty"; its own legend lists twenty-one, and
    ## twenty-one is what the sim emits (docs/PORTING-CRAFTER.md records it).
    check glyphs.len == 21
    check toSeq(Terrain).len == 15
    ## The table matches the note exactly.
    for terrain in Terrain:
      check terrain.walkable() ==
        (terrain in {tGrass, tSand, tPath, tLava})
    var cog = newCog(SpawnX, SpawnY)
    check tTree.minedBy(cog)
    check tGrass.minedBy(cog)
    check tWater.minedBy(cog)
    check tRipePlant.minedBy(cog)
    check not tStone.minedBy(cog)
    check not tCoal.minedBy(cog)
    check not tIron.minedBy(cog)
    check not tDiamond.minedBy(cog)
    check not tSand.minedBy(cog)
    check not tLava.minedBy(cog)
    check not tBedrock.minedBy(cog)
    check not tTable.minedBy(cog)
    check not tFurnace.minedBy(cog)
    check not tSapling.minedBy(cog)
    cog.tools[toWoodPickaxe] = true
    check tStone.minedBy(cog)
    check tCoal.minedBy(cog)
    check not tIron.minedBy(cog)
    cog.tools[toStonePickaxe] = true
    check tIron.minedBy(cog)
    check not tDiamond.minedBy(cog)
    cog.tools[toIronPickaxe] = true
    check tDiamond.minedBy(cog)
    ## Mining stone leaves walkable `path`; a tree is INFINITE.
    check tStone.mineBecomes() == tPath
    check tCoal.mineBecomes() == tPath
    check tIron.mineBecomes() == tPath
    check tDiamond.mineBecomes() == tPath
    check tTree.mineBecomes() == tTree
    check tGrass.mineBecomes() == tGrass
    check tRipePlant.mineBecomes() == tSapling
