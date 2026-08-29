## The baseline grid sweep. The shipped `DefaultBaselineParams` are the pick
## of this harness, not a guess: it plays BOTH shipped variants over a bounded
## matrix of the tunables and prints the table.
##
##   nim c -r --path:src tools/tune_baselines.nim            # print the sweep
##   nim c -r --path:src tools/tune_baselines.nim --check    # assert the pick
##
## `tools/ci/baseline_tuning.json` records the winning cell and
## `tests/test_crafter_driver.nim` asserts the shipped defaults still equal
## it, so a retuned baseline and its recorded sweep land in one commit.
##
## The metric is TOTAL ACHIEVEMENTS UNLOCKED over the sweep seeds of both
## variants, ties broken by total survival ticks — the two terms of
## `scores[0]`, in that order, which is what the league ranks.

import std/[json, os, strformat, strutils]
import crafter/[sim, driver, baselines]

const SweepSeeds = 40

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

when isMainModule:
  let check = "--check" in commandLineParams()
  var
    best = DefaultBaselineParams
    bestOutcome = (unlocked: -1, ticks: -1)
    grid = newJArray()
  for exploreSteps in [2, 3, 4, 5]:
    for hungerThreshold in [3, 4, 5]:
      for restThreshold in [5, 6, 7]:
        for sleepTicks in [8, 12, 16]:
          for shelterStones in [2, 4]:
            for tieBreakByDistance in [false, true]:
              var params = DefaultBaselineParams
              params.exploreSteps = exploreSteps
              params.hungerThreshold = hungerThreshold
              params.restThreshold = restThreshold
              params.sleepTicks = sleepTicks
              params.shelterStones = shelterStones
              params.tieBreakByDistance = tieBreakByDistance
              let outcome = evaluate(params)
              grid.add(cellJson(params, outcome))
              if outcome.unlocked > bestOutcome.unlocked or
                  (outcome.unlocked == bestOutcome.unlocked and
                   outcome.ticks > bestOutcome.ticks):
                best = params
                bestOutcome = outcome
              if not check:
                echo &"explore={exploreSteps} hunger={hungerThreshold} " &
                  &"rest={restThreshold} sleep={sleepTicks} " &
                  &"shelter={shelterStones} tie={tieBreakByDistance} " &
                  &"achievements={outcome.unlocked} ticks={outcome.ticks}"
  echo "PICK: ", cellJson(best, bestOutcome)
  if check:
    if best != DefaultBaselineParams:
      echo "::error::the sweep's pick is no longer the shipped defaults"
      quit(1)
    echo "the shipped DefaultBaselineParams are still the sweep's pick"
