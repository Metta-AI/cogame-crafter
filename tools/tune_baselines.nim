## The baseline grid sweep. The shipped `DefaultBaselineParams` are the pick
## of this harness, not a guess: it plays BOTH shipped variants over EVERY cell
## of a bounded matrix of the tunables and prints the whole table.
##
##   nim c -r --path:src tools/tune_baselines.nim            # print the sweep
##   nim c -r --path:src tools/tune_baselines.nim --json     # the recorded file
##   nim c -r --path:src tools/tune_baselines.nim --check    # assert the pick
##
## `tools/ci/baseline_tuning.json` IS `--json`'s output, cell for cell, and
## `tests/test_crafter_driver.nim` asserts the shipped defaults still equal its
## `pick`, so a retuned baseline and its recorded sweep land in one commit.
##
## The metric is TOTAL ACHIEVEMENTS UNLOCKED over the sweep seeds of both
## variants, ties broken by total survival ticks — the two terms of
## `scores[0]`, in that order, which is what the league ranks.
##
## THE PICK IS CONSTRAINED, and the constraint is not a thumb on the scale: the
## certification fixture is a `forager` episode on seed 42 of `standard`, and
## that same episode is the replay `docker_smoke.sh` produces and the
## `wasm-viewer` job loads in a browser under `viewer_smoke.mjs --soak 10`. A
## cell that scores well by dying at tick 400 makes the certification replay
## barely outlast the soak (the ecos 2026-08-23 scar), and
## `tests/test_crafter_engine.nim` asserts that floor directly. So a cell is
## only eligible if its cert-seed episode survives >= `CertMinTicks` ticks and
## unlocks >= `CertMinUnlocked`.

import std/[json, os, strformat, strutils]
import crafter/[sim, driver, baselines]

const
  SweepSeeds = 40
  CertMinTicks = 900
    ## The certification/CI replay must outlast `viewer_smoke.mjs --soak 10` by
    ## a wide margin; at ReplayFps this is 39 s of playback.
  CertMinUnlocked = 6
    ## ...and it has to exercise what the viewer draws.

proc sweepConfig(variant: string, seed: int): GameConfig =
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

proc playOne(config: GameConfig, kind: Baseline,
             params: BaselineParams): tuple[unlocked, ticks: int] =
  var sim = initSimServer(config)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.startRun()
  while sim.phase == Playing:
    if sim.waitingForPlan():
      if not sim.beginTurn():
        break
      let plan = scriptedPlan(sim, kind, params)
      let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
        plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks,
        sim.hostileCells())
      sim.installPlan(expansion.primitives, expansion.truncated,
        plan.dropped + plan.overCap, expansion.unreachable)
    sim.stepTick()
    sim.pending.setLen(0)
  if sim.phase == Playing:
    sim.finish(erComplete, edTurnCap)
  (sim.achievementsUnlocked(), sim.survivalTicks())

proc evaluate(params: BaselineParams): tuple[unlocked, ticks: int] =
  for variant in ["standard", "longnight"]:
    for seed in 1 .. SweepSeeds:
      let outcome = playOne(sweepConfig(variant, seed), blForager, params)
      result.unlocked += outcome.unlocked
      result.ticks += outcome.ticks

proc cellJson(params: BaselineParams,
              outcome: tuple[unlocked, ticks: int]): JsonNode =
  %*{
    "exploreSteps": params.exploreSteps,
    "hungerThreshold": params.hungerThreshold,
    "restThreshold": params.restThreshold,
    "sleepTicks": params.sleepTicks,
    "shelterStones": params.shelterStones,
    "thirstThreshold": params.thirstThreshold,
    "tieBreakByDistance": params.tieBreakByDistance,
    "achievements": outcome.unlocked,
    "ticks": outcome.ticks
  }

proc certOutcome(params: BaselineParams): tuple[unlocked, ticks: int] =
  ## The certification fixture's own episode, played with this cell.
  playOne(sweepConfig("standard", 42), blForager, params)

when isMainModule:
  let check = "--check" in commandLineParams()
  let emitJson = "--json" in commandLineParams()
  let quiet = check or emitJson
  var
    best = DefaultBaselineParams
    bestOutcome = (unlocked: -1, ticks: -1)
    grid = newJArray()
  for exploreSteps in [2, 3, 4, 5]:
    for hungerThreshold in [3, 4, 5]:
      for thirstThreshold in [2, 3, 4]:
        for restThreshold in [5, 6, 7]:
          for sleepTicks in [8, 12, 16]:
            for shelterStones in [2, 4]:
              for tieBreakByDistance in [false, true]:
                var params = DefaultBaselineParams
                params.exploreSteps = exploreSteps
                params.hungerThreshold = hungerThreshold
                params.thirstThreshold = thirstThreshold
                params.restThreshold = restThreshold
                params.sleepTicks = sleepTicks
                params.shelterStones = shelterStones
                params.tieBreakByDistance = tieBreakByDistance
                let outcome = evaluate(params)
                let cert = certOutcome(params)
                var cell = cellJson(params, outcome)
                cell["certTicks"] = %cert.ticks
                cell["certUnlocked"] = %cert.unlocked
                grid.add(cell)
                let eligible = cert.ticks >= CertMinTicks and
                  cert.unlocked >= CertMinUnlocked
                if eligible and (outcome.unlocked > bestOutcome.unlocked or
                    (outcome.unlocked == bestOutcome.unlocked and
                     outcome.ticks > bestOutcome.ticks)):
                  best = params
                  bestOutcome = outcome
                if not quiet:
                  echo &"explore={exploreSteps} hunger={hungerThreshold} " &
                    &"thirst={thirstThreshold} rest={restThreshold} " &
                    &"sleep={sleepTicks} shelter={shelterStones} " &
                    &"tie={tieBreakByDistance} " &
                    &"achievements={outcome.unlocked} ticks={outcome.ticks} " &
                    &"certTicks={cert.ticks} eligible={eligible}"
  if emitJson:
    let certBest = certOutcome(best)
    var pick = cellJson(best, bestOutcome)
    pick["certTicks"] = %certBest.ticks
    pick["certUnlocked"] = %certBest.unlocked
    ## One cell per LINE: 1296 cells pretty-printed is a third of a megabyte
    ## of JSON nobody can read in a diff.
    let note = "The grid harness's output, cell for cell, not a guess: " &
      "`nim c -r --path:src tools/tune_baselines.nim --json` prints THIS " &
      "file. Every cell of the matrix is played over both shipped variants " &
      "and seeds 1..40; tests/test_crafter_driver.nim asserts the shipped " &
      "DefaultBaselineParams still equal `pick`."
    let metric = "total achievements unlocked by `forager` over seeds 1..40 " &
      "of both shipped variants, ties broken by total survival ticks, " &
      "restricted to cells whose certification-seed episode (seed 42, " &
      "standard) survives >= 900 ticks and unlocks >= 6 - that episode is " &
      "the CI replay the viewer soak runs against"
    var document = "{\n  \"note\": " & $(%note) &
      ",\n  \"metric\": " & $(%metric) &
      ",\n  \"pick\": " & $pick & ",\n  \"grid\": [\n"
    for i in 0 ..< grid.len:
      document.add("    " & $grid[i])
      document.add(if i + 1 < grid.len: ",\n" else: "\n")
    document.add("  ]\n}")
    echo document
    quit(0)
  echo "PICK: ", cellJson(best, bestOutcome)
  if check:
    if best != DefaultBaselineParams:
      echo "::error::the sweep's pick is no longer the shipped defaults"
      quit(1)
    echo "the shipped DefaultBaselineParams are still the sweep's pick"
