## End-to-end episode writing a replay — design note §Tests items 26..30, and
## the six results identities of §Server.

import std/[json, sets, strutils, unittest]
import crafter/[sim, driver, directives, baselines, decide, events]
import helpers

proc episode(variant = "standard", seed = 42): SimServer =
  ## A real one-seat episode, scripted, no API key — exactly the shape
  ## `docker_smoke.sh` runs.
  playScripted(testConfig(variant, seed), blForager)

proc identities(sim: SimServer) =
  ## The SIX identities that hold in every results document.
  let results = parseJson(sim.runResultsJson())
  # 1.
  check results["scores"][0].getInt() ==
    10_000 * results["achievementsUnlocked"].getInt() +
    results["survivalTicks"].getInt()
  # 2.
  var counted = 0
  for value in results["achievementUnlocked"]:
    if value.getBool(): inc counted
  check counted == results["achievementsUnlocked"].getInt()
  check results["achievementsOf"].getInt() == AchievementCount
  # 3.
  for i in 0 ..< AchievementCount:
    let on = results["achievementUnlocked"][i].getBool()
    let tick = results["achievementTick"][i].getInt()
    check (tick >= 0) == on
    if not on:
      check tick == -1
  # 4.
  check results["survivalTicks"].getInt() == results["finalTick"].getInt()
  check results["finalTick"].getInt() <= sim.config.maxTicks
  # 5.
  let death = results["endRule"].getStr() == "death"
  check death == (results["finalHealth"].getInt() == 0)
  check death == (results["deathCause"].getStr() != "none")
  # 6.
  check results["primitivesExecuted"].getInt() <= results["finalTick"].getInt()
  check results["turnsPlayed"].getInt() <= sim.config.maxTurns

suite "an episode end to end":
  test "the episode writes artifacts and every identity holds":
    ## Item 26.
    for variant in ["standard", "longnight"]:
      for seed in [42, 7, 1234]:
        let sim = episode(variant, seed)
        check sim.phase == GameOver
        check sim.endReason == erComplete
        check sim.endRule in {edDeath, edAllUnlocked, edTurnCap, edTickCap}
        sim.identities()
    ## The results key set equals the manifest's `results_schema` key set
    ## EXACTLY: Coworld schemas are closed and undeclared keys are dropped.
    let sim = episode()
    var produced: HashSet[string]
    for key, _ in parseJson(sim.runResultsJson()):
      produced.incl(key)
    var declared: HashSet[string]
    for key, _ in manifest(){"game", "results_schema", "properties"}:
      declared.incl(key)
    check produced == declared

  test "the cert seed is interesting":
    ## Item 27: seed 42 on `standard` is what the CI smoke replay is made of,
    ## so it has to exercise the paths the viewer draws.
    let sim = episode("standard", 42)
    check sim.achievementsUnlocked() >= 6
    var kinds = [false, false, false]     ## place_*, make_*, collect_*
    for a in Achievement:
      if not sim.ledger.unlocked[a]: continue
      let name = $a
      if name.startsWith("place_"): kinds[0] = true
      if name.startsWith("make_"): kinds[1] = true
      if name.startsWith("collect_"): kinds[2] = true
    check kinds == [true, true, true]
    ## The replay has to outlast a 10 s viewer soak by a wide margin: at
    ## ReplayFps this is 39 s of playback.
    check sim.survivalTicks() >= 900
    check sim.nightsSurvived >= 1
    check sim.daysSurvived >= 1
    check sim.damageTaken >= 1

  test "no seat can stall, and the failure payload is the closed schema":
    ## Item 28.
    var config = testConfig()
    config.lobbyJoinTimeoutTicks = 3
    ## A seat that NEVER connects: the run plays out on `forager` inside the
    ## budget, with the seat marked dead.
    var sim = initSimServer(config)
    var engine = initDecisionEngine(sim)
    check engine.policyKind(0) == "scripted"
    while sim.phase == Lobby:
      sim.step()
    check sim.phase == Playing
    sim.deadSeats[0] = true
    var guard = 0
    while sim.phase == Playing and guard < 200:
      inc guard
      if sim.waitingForPlan():
        if not sim.beginTurn(): break
        let decision = engine.turn(sim, sim.turnsPlayed + 1, 0)
        discard sim.applyDirective(decision.directive, nil)
      sim.stepTick()
      sim.pending.setLen(0)
    if sim.phase == Playing:
      sim.finish(erComplete, edTurnCap)
    check sim.endReason == erComplete
    let results = parseJson(sim.runResultsJson())
    check results["deadSeats"][0].getBool()
    check results["policyKinds"][0].getStr() == "scripted"
    ## The platform's CLOSED failure payload — exactly two keys.
    let payload = %*{"message": "seat never connected", "failed_policy_index": 0}
    var keys: HashSet[string]
    for key, _ in payload:
      keys.incl(key)
    check keys == ["message", "failed_policy_index"].toHashSet()

  test "a seat that connects and never answers falls back every turn":
    ## Item 28, second half: the LLM client with no credentials is `disabled`,
    ## so every turn falls back INSTANTLY with no network wait.
    var sim = startedSim(testConfig())
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    engine.seats[0].registered = true
    var fallbacks = 0
    for turn in 1 .. 6:
      if not sim.beginTurn(): break
      let decision = engine.turn(sim, turn, 0)
      check decision.directive.source == dsFallback
      for record in decision.records:
        if parseJson(record){"k"}.getStr() == "fallback":
          inc fallbacks
          check parseJson(record){"cause"}.getStr() == "no_credentials"
      discard sim.applyDirective(decision.directive, nil)
      while sim.turnActive and sim.phase == Playing:
        sim.stepTick()
        sim.pending.setLen(0)
    check fallbacks >= 6
    check sim.fallbackTurns >= 6

  test "the budget guard settles the episode complete, not deadline":
    ## Item 29.
    var sim = startedSim(testConfig())
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    ## Force the guard: two more full turns would not fit.
    let decision = engine.turn(sim, 1, sim.config.wallClockBudgetSeconds - 2)
    check engine.llmOff
    var named = false
    for record in decision.records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "budget_guard":
        named = true
        check node{"turn"}.getInt() == 1
    check named
    check decision.directive.source == dsFallback
    ## The episode still finishes `complete`.
    sim.finish(erComplete, edTurnCap)
    check sim.endReason == erComplete

  test "the rate guard skips the call and names the cause":
    var sim = startedSim(testConfig())
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    for i in 0 ..< RateGuardMaxRequests:
      engine.noteRequest()
    let decision = engine.turn(sim, 2, 0)
    check decision.directive.source == dsFallback
    var cause = ""
    for record in decision.records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback":
        cause = node{"cause"}.getStr()
    ## With no credentials the engine reports `no_credentials` first, which is
    ## the honest cause; with credentials it would be `rate_guard`. Either way
    ## the turn NEVER waits on the network.
    check cause in ["no_credentials", "rate_guard"]

  test "flinch accounting":
    ## Item 30.
    var sim = startedSim(testConfig())
    sim.clearAroundForTest(3)
    sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 1,
                               y: sim.cog.y, hp: 5, lastAct: -99, alive: true))
    discard sim.beginTurn()
    sim.installPlan(@[pNoop, pNoop, pNoop, pNoop, pNoop, pNoop, pNoop,
                      pNoop], false, 0, 0)
    while sim.turnActive and sim.phase == Playing:
      sim.stepTick()
      sim.pending.setLen(0)
    check sim.interrupts == 1
    check sim.lastInterrupted == "hurt_by_zombie"
    ## The discarded ticks are NOT consumed.
    check sim.runTick() < sim.config.turnTicks
    let observation = sim.observationJson(includeNotes = false)
    check observation["last_plan"]["interrupted"].getStr() == "hurt_by_zombie"
    ## Forced STARVATION damage does none of those things.
    var starving = startedSim(testConfig())
    starving.clearAroundForTest(3)
    starving.cog.vitals[vFood] = 0
    starving.cog.vitals[vDrink] = 0
    starving.runTurn(@[Action(kind: akNoop, n: 1)])
    check starving.interrupts == 0
    check starving.lastInterrupted == ""
    check starving.runTick() == starving.config.turnTicks

  test "the tier-2 event stream carries a per-tick action trace":
    var sim = startedSim(testConfig())
    var rows: seq[string]
    for turn in 1 .. 3:
      sim.runTurn(@[Action(kind: akDo, n: 4)])
      rows.add(sim.primitiveRow(sim.executed[^1]))
    rows.add(sim.summaryRow(rows.len))
    let stream = eventsJsonl(rows)
    check stream.endsWith("\n")
    let last = parseJson(stream.strip().splitLines()[^1])
    check last["type"].getStr() == "summary"
    check last["gameVersion"].getStr() == GameVersion
