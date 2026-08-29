## Events — design note §Tests item 48, and the tier-2 analysis stream.

import std/[json, sets, strutils, tables, unittest]
import crafter/[sim, driver, baselines, events, broadcast]
import helpers

const
  ## The CLOSED enum of twenty-one derived broadcast kinds, plus `end`.
  DeclaredKinds = ["turn", "plan", "say", "fallback", "achievement", "collect",
                   "craft", "place", "eat", "drink", "hurt", "heal", "kill",
                   "spawn", "burn", "sleep", "nightfall", "daybreak", "starve",
                   "death", "budget", "end"]
  ## The scrubber's beat kinds, and the ONLY kinds the appended game block
  ## draws a marker for.
  BeatKinds = ["achievement", "nightfall", "daybreak", "kill", "death",
               "fallback", "end"]

suite "the derived event vocabulary":
  test "the emitted set equals exactly the declared list":
    var declared: HashSet[string]
    for kind in EventKind:
      declared.incl($kind)
    check declared == DeclaredKinds.toHashSet()
    check declared.len == DeclaredKinds.len

  test "isBeat is exactly the seven documented kinds":
    var beats: HashSet[string]
    for kind in EventKind:
      if kind.isBeat():
        beats.incl($kind)
    check beats == BeatKinds.toHashSet()

  test "every kind the appended game block handles is in the set":
    ## The block's `switch (e.k)` and its beat builder may only name kinds the
    ## sim can emit; a case for a kind that never arrives is dead chrome and a
    ## kind with no case is a silent gap.
    let block1 = readRepo("client/crafter_block.html")
    var handled: HashSet[string]
    for line in block1.splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("case '"):
        continue
      let name = trimmed.split('\'')[1]
      handled.incl(name)
    ## Every kind the block handles is a real one...
    for name in handled:
      check name in DeclaredKinds
    ## ...and every beat kind is one the block actually draws.
    for name in BeatKinds:
      check name in handled

  test "every event shape carries the documented fields":
    var sim = startedSim(testConfig())
    for kind in EventKind:
      let node = sim.eventJson(SimEvent(kind: kind, tick: 7, i: 1, x: 2, y: 3,
                                        n: 4, m: 5, a: "a", b: "b", c: "c"))
      check node["k"].getStr() == $kind
      check node["t"].getInt() == 7
      case kind
      of evAchievement:
        check node.hasKey("id")
        check node.hasKey("index")
        check node.hasKey("of")
      of evNightfall, evDaybreak:
        check node.hasKey("day")
      of evKill, evSpawn:
        check node.hasKey("what")
        check node.hasKey("x")
      of evHurt:
        check node.hasKey("by")
        check node.hasKey("amount")
        check node.hasKey("hp")
      of evDeath:
        check node.hasKey("by")
      of evEnd:
        check node.hasKey("reason")
        check node.hasKey("endRule")
        check node.hasKey("unlocked")
        check node.hasKey("score")
      else:
        discard

  test "nothing fires unconditionally per tick, so the feed never floods":
    var sim = startedSim(testConfig())
    var counts = initCountTable[EventKind]()
    var ticks = 0
    while sim.phase == Playing and ticks < 600:
      if sim.waitingForPlan():
        if not sim.beginTurn(): break
        let plan = scriptedPlan(sim, blForager)
        let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
          plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks,
          sim.hostileCells())
        sim.installPlan(expansion.primitives, expansion.truncated, 0,
                        expansion.unreachable)
      sim.stepTick()
      inc ticks
      for event in sim.pending:
        counts.inc(event.kind)
      sim.pending.setLen(0)
    ## `plan` fires once per turn (<= 56), `achievement` at most 22 times,
    ## `nightfall` / `daybreak` at most 8 each.
    check counts[evAchievement] <= AchievementCount
    check counts[evNightfall] <= 8
    check counts[evDaybreak] <= 8
    check counts[evTurn] <= sim.config.maxTurns
    ## And no kind fires on every single tick.
    for kind in EventKind:
      check counts[kind] < ticks

suite "the tier-2 analysis stream":
  test "every derived kind maps into the analysis enum, or is deliberately not":
    var mapped = 0
    for kind in EventKind:
      if kind.analysisKind().ok:
        inc mapped
    ## `say`, `budget` and `end` are broadcast-only: the analysis stream
    ## carries the ACTIONS and the world's reactions to them, and the
    ## `budget_guard` and `stop` facts live in the replay's control records.
    check mapped == DeclaredKinds.len - 3
    check not evSay.analysisKind().ok
    check not evBudget.analysisKind().ok
    check not evEnd.analysisKind().ok

  test "the summary row is mandatory and carries the GameVersion":
    var sim = startedSim(testConfig())
    let row = parseJson(sim.summaryRow(17))
    check row["type"].getStr() == "summary"
    check row["events"].getInt() == 17
    check row["gameVersion"].getStr() == GameVersion
    check row["ticks"].getInt() == sim.tickCount
