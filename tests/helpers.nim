## Shared test helpers.
import std/[json, os, random]
import crafter/[sim, driver, directives, baselines]

proc testConfig*(variant = "standard", seed = 42): GameConfig =
  ## The shipped variants, exactly as `coworld_manifest_template.json`
  ## declares them — `tests/test_crafter_manifest.nim` cross-checks that.
  result = defaultGameConfig()
  result.seed = seed
  result.variant = variant
  if variant == "longnight":
    result.dayLength = 160
    result.dayFraction = 80
    result.mountainThreshold = 660
    result.maxCows = 8
    result.maxZombies = 12
    result.parAchievements = 6
  result.wallClockBudgetSeconds = 240
  result.lobbyJoinTimeoutTicks = 4

proc startedSim*(config: GameConfig): SimServer =
  ## A sim in `Playing` with the world generated and the cog placed, exactly
  ## the state the server's lobby transition leaves behind.
  result = initSimServer(config)
  result.phase = Playing
  result.gameStartTick = result.tickCount
  result.startRun()

proc runTurn*(sim: var SimServer, actions: seq[Action]) =
  ## One command turn, driven exactly the way `server.nim`'s turn boundary
  ## drives it: expand against the known map as of turn start, install, then
  ## step until the turn's tick budget runs out (or a flinch ends it early).
  if not sim.beginTurn():
    return
  let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y, actions,
    sim.config.macroPrimitiveCap, sim.config.turnTicks, sim.hostileCells())
  sim.installPlan(expansion.primitives, expansion.truncated, 0,
    expansion.unreachable)
  while sim.turnActive and sim.phase == Playing:
    sim.stepTick()
    sim.pending.setLen(0)

proc playScripted*(config: GameConfig, kind = blForager,
                   params = DefaultBaselineParams,
                   maxTurns = 400): SimServer =
  ## A whole scripted episode, driven exactly the way `server.nim`'s turn
  ## boundary drives it.
  result = startedSim(config)
  var turns = 0
  while result.phase == Playing and turns < maxTurns:
    if result.waitingForPlan():
      if not result.beginTurn():
        break
      let plan = scriptedPlan(result, kind, params)
      let expansion = expandPlan(result.knownMap, result.cog.x, result.cog.y,
        plan.actions, result.config.macroPrimitiveCap, result.config.turnTicks,
        result.hostileCells())
      result.installPlan(expansion.primitives, expansion.truncated,
        plan.dropped + plan.overCap, expansion.unreachable)
      inc turns
    result.stepTick()
    result.pending.setLen(0)
  if result.phase == Playing:
    result.finish(erComplete, edTurnCap)

proc clearAroundForTest*(sim: var SimServer, radius = 3, terrain = tGrass) =
  ## Flatten the ground around the cog so a test is about the rule it names
  ## and not about whatever the generator happened to put there.
  for dy in -radius .. radius:
    for dx in -radius .. radius:
      sim.world.setAt(sim.cog.x + dx, sim.cog.y + dy, terrain)
  sim.terrainHash = sim.world.terrainDigest()
  discard sim.knownMap.mergeVisible(sim.world, sim.cog.x, sim.cog.y,
                                    sim.tickCount)

proc revealAll*(sim: var SimServer) =
  ## Reveal the whole true grid into the known map — the state a `goto` test
  ## needs when it wants the BFS to be about the terrain, not about
  ## exploration.
  for slot in 0 ..< WorldCells:
    sim.knownMap.cells[slot].seen = true
    sim.knownMap.cells[slot].terrain = sim.world.cells[slot]
    sim.knownMap.cells[slot].seenTick = sim.tickCount

proc randomKnownMap*(sim: var SimServer, rng: var Rand, fraction: int) =
  ## Reveal a pseudo-random subset of the true grid, so the baselines are
  ## exercised against partial maps rather than a fully explored one.
  for slot in 0 ..< WorldCells:
    if rng.rand(99) < fraction:
      sim.knownMap.cells[slot].seen = true
      sim.knownMap.cells[slot].terrain = sim.world.cells[slot]
      sim.knownMap.cells[slot].seenTick = sim.tickCount

proc repoRoot*(): string =
  ## Tests run from the repo ROOT (`nim r --path:src tests/x.nim`), but also
  ## work from tests/ via tests/config.nims.
  if fileExists("coworld_manifest_template.json"): "."
  elif fileExists("../coworld_manifest_template.json"): ".."
  else: "../.."

proc readRepo*(path: string): string = readFile(repoRoot() / path)

proc manifest*(): JsonNode =
  parseJson(readRepo("coworld_manifest_template.json"))
