## Bounded orders and legality on the scripted baselines, the driver and the
## reply validator — design note §Tests items 19..25.

import std/[json, random, unicode, unittest]
import crafter/[sim, driver, directives, baselines, decide]
import helpers

const Verbs = block:
  var names: seq[string]
  for kind in ActionKind:
    names.add($kind)
  names

proc pseudoStates(count: int): seq[SimServer] =
  ## `count` pseudo-random world states across both variants, day and night,
  ## every vitals combination, empty and full inventories, and adjacent to
  ## lava, water and hostiles.
  var rng = initRand(20260828)
  for i in 0 ..< count:
    let variant = if i mod 2 == 0: "standard" else: "longnight"
    var sim = startedSim(testConfig(variant, seed = 100 + i))
    sim.tickCount = sim.gameStartTick + rng.rand(0 .. 1300)
    sim.randomKnownMap(rng, rng.rand(5 .. 95))
    for vital in Vital:
      sim.cog.vitals[vital] = rng.rand(0 .. VitalMax)
    for resource in Resource:
      sim.cog.inventory[resource] =
        if i mod 3 == 0: 0 elif i mod 3 == 1: InventoryMax
        else: rng.rand(0 .. InventoryMax)
    for tool in Tool:
      sim.cog.tools[tool] = rng.rand(0 .. 1) == 1
    sim.cog.facing = Facings[rng.rand(0 .. 3)]
    ## Put lava, water and a hostile right next to the cog on every third
    ## state, so the "never suicide" rule is actually exercised.
    if i mod 3 == 0:
      sim.world.setAt(sim.cog.x + 1, sim.cog.y, tLava)
      sim.world.setAt(sim.cog.x - 1, sim.cog.y, tWater)
      sim.world.setAt(sim.cog.x, sim.cog.y - 1, tLava)
      sim.terrainHash = sim.world.terrainDigest()
      discard sim.knownMap.mergeVisible(sim.world, sim.cog.x, sim.cog.y,
                                        sim.tickCount)
      sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 2,
                                 y: sim.cog.y + 1, hp: 5, alive: true))
      sim.herd.list.add(Creature(kind: ckSkeleton, x: sim.cog.x - 2,
                                 y: sim.cog.y - 2, hp: 3, alive: true))
    if i mod 5 == 0:
      sim.herd.list.add(Creature(kind: ckCow, x: sim.cog.x + 3,
                                 y: sim.cog.y, hp: 3, alive: true))
    result.add(sim)

suite "the scripted baselines are bounded and legal":
  let states = pseudoStates(300)

  test "baselines are bounded":
    ## Item 19.
    for kind in [blForager, blWanderer]:
      for sim in states:
        let plan = scriptedPlan(sim, kind)
        check plan.actions.len <= sim.config.maxActionsPerTurn
        check plan.say.len == 0
        check plan.notes.len == 0
        check plan.source == dsScripted
        for action in plan.actions:
          check $action.kind in Verbs
          case action.kind
          of akGoto:
            check action.x in 0 ..< WorldSize
            check action.y in 0 ..< WorldSize
          of akMove:
            check action.n in 1 .. 12
          of akDo:
            check action.n in 1 .. 12
          of akSleep:
            check action.n in 1 .. 24
          else:
            check action.n == 1
        ## The serialised directive stays small.
        let record = $plan.directiveRecord(1, sim.tickCount, 0, seatAlias(0),
          @[], false, 0, 0, "", nil)
        check record.len <= 1024

  test "baselines never suicide, and forager never routes through the unknown":
    ## Item 20.
    for kind in [blForager, blWanderer]:
      for sim in states:
        let plan = scriptedPlan(sim, kind)
        let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
          plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks,
          sim.hostileCells())
        var x = sim.cog.x
        var y = sim.cog.y
        for primitive in expansion.primitives:
          let moving = moveFacing(primitive)
          if not moving.ok:
            continue
          let
            nx = x + FacingDx[moving.dir]
            ny = y + FacingDy[moving.dir]
          let entry = sim.knownMap.known(nx, ny)
          ## A step onto a cell the cog KNOWS is lava is suicide.
          check not (entry.seen and entry.terrain == tLava)
          if sim.world.at(nx, ny).walkable():
            x = nx
            y = ny
        ## The BFS the forager's `goto` runs on never crosses `?`.
        for action in plan.actions:
          if action.kind != akGoto:
            continue
          let walk = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
            action.x, action.y, sim.config.macroPrimitiveCap)
          var wx = sim.cog.x
          var wy = sim.cog.y
          for primitive in walk.primitives:
            let moving = moveFacing(primitive)
            if not moving.ok:
              continue
            let
              nx = wx + FacingDx[moving.dir]
              ny = wy + FacingDy[moving.dir]
            if sim.knownMap.traversable(nx, ny):
              check sim.knownMap.known(nx, ny).seen
              wx = nx
              wy = ny

  test "the driver never produces an illegal primitive":
    ## Item 21.
    for kind in [blForager, blWanderer]:
      for sim in states:
        let plan = scriptedPlan(sim, kind)
        let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
          plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks,
          sim.hostileCells())
        check expansion.primitives.len <= sim.config.turnTicks
        for primitive in expansion.primitives:
          check ord(primitive) in ord(low(Primitive)) .. ord(high(Primitive))
        ## A macro expands to at most macroPrimitiveCap.
        for action in plan.actions:
          if action.kind != akGoto:
            continue
          let walk = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
            action.x, action.y, sim.config.macroPrimitiveCap)
          check walk.primitives.len <= sim.config.macroPrimitiveCap
    ## An EMPTY queue yields `noop`, never nothing: a turn is turnTicks ticks.
    var sim = startedSim(testConfig())
    discard sim.beginTurn()
    sim.installPlan(@[], false, 0, 0)
    sim.stepTick()
    check sim.executed == @[pNoop]

  test "the fallback IS the forager proc":
    ## Item 22: the decision engine's fallback path and the `forager` baseline
    ## resolve to the same proc, so they cannot drift.
    for sim in states[0 .. 39]:
      let fallback = foragerFallback(sim)
      let baseline = scriptedPlan(sim, blForager)
      check fallback.actions == baseline.actions
      check fallback.source == dsFallback
      check baseline.source == dsScripted

suite "reply validation":
  test "the validator accepts the schema and drops what does not validate":
    ## Item 23.
    let payload = parseJson("""{"actions":[
      {"act":"goto","x":35,"y":25},
      {"act":"do","n":4},
      {"act":"make_stone_sword"},
      {"act":"MOVE-UP"},
      {"act":"move","dir":"N","n":99},
      {"act":"sleep","n":40},
      {"act":"goto","y":3},
      {"act":"move","dir":"sideways"},
      {"act":"teleport"},
      {"act":"goto","x":-4,"y":900}],
      "say":"planning","notes":"scratch"}""")
    let directive = parseDirective(payload, 12)
    ## Dropped, never rewritten: the bad goto, the bad dir and the unknown verb.
    check directive.dropped == 3
    let kinds = block:
      var names: seq[string]
      for action in directive.actions:
        names.add($action.kind)
      names
    check kinds == @["goto", "do", "make_stone_sword", "move_up", "move",
                     "sleep", "goto"]
    ## `n` is clamped into its range; `goto` coordinates are clamped to 0..63.
    check directive.actions[1].n == 4
    check directive.actions[4].n == 12          ## move caps at 12
    check directive.actions[4].dir == fUp       ## "N" case-folds to up
    check directive.actions[5].n == 24          ## sleep caps at 24
    check directive.actions[6].x == 0
    check directive.actions[6].y == WorldSize - 1

  test "a say-only reply is usable; a non-object is not":
    var directive = parseDirective(parseJson("""{"say":"thinking"}"""), 12)
    check directive.actions.len == 0
    check directive.say == "thinking"
    expect DirectiveError:
      discard parseDirective(parseJson("[]"), 12)
    expect DirectiveError:
      discard extractJsonObject("no braces at all")
    ## Fence-tolerant, prose-tolerant extraction.
    let fenced = extractJsonObject(
      "here you go:\n```json\n{\"say\":\"x\"}\n```\nok")
    check fenced{"say"}.getStr() == "x"

  test "say and notes truncate on RUNE boundaries with 4-byte emoji on the cap":
    ## Item 23's rune clause. A byte slice would cut a codepoint in half and
    ## the replay would then fail a strict UTF-8 parser.
    let emoji = "\u{1F9E9}"                     ## a 4-byte codepoint
    var say = ""
    for i in 0 ..< MaxSayRunes + 40:
      say.add(emoji)
    var notes = ""
    for i in 0 ..< MaxNoteRunes + 40:
      notes.add(emoji)
    let directive = parseDirective(%*{"say": say, "notes": notes}, 12)
    check directive.say.runeLen == MaxSayRunes
    check directive.notes.runeLen == MaxNoteRunes
    check directive.say.len == MaxSayRunes * 4  ## whole codepoints, every one
    check directive.notes.validateUtf8() == -1
    check directive.say.validateUtf8() == -1

  test "actions cap at 12 and the surplus is counted, not dropped silently":
    var entries = newJArray()
    for i in 0 .. 19:
      entries.add(%*{"act": "do"})
    let directive = parseDirective(%*{"actions": entries}, 12)
    check directive.actions.len == 12
    check directive.overCap == 8
    check directive.dropped == 0

  test "truncated, dropped, unreachable and interrupted are reported back":
    var sim = startedSim(testConfig())
    sim.clearAroundForTest()
    var directive = Directive(source: dsLlm)
    for i in 0 .. 29:
      directive.actions.add(Action(kind: akDo, n: 1))
    directive.actions.add(Action(kind: akGoto, x: 2, y: 2, n: 1))
    directive.dropped = 2
    directive.overCap = 3
    sim.lastInterrupted = "hurt_by_zombie"
    let record = parseJson(sim.applyDirective(directive, nil))
    check record["truncated"].getBool()
    check record["unreachable"].getInt() == 1
    check record["dropped"].getInt() == 3
    check record["interrupted"].getStr() == "hurt_by_zombie"
    check sim.repliesRepaired == 2
    let observation = sim.observationJson(includeNotes = true)
    check observation["last_plan"]["truncated"].getBool()
    check observation["last_plan"]["unreachable"].getInt() == 1

suite "baseline tuning and the controls":
  test "the shipped thresholds equal the swept pick":
    ## Item 24.
    let sweep = parseJson(readRepo("tools/ci/baseline_tuning.json"))
    let pick = sweep["pick"]
    check pick["thirstThreshold"].getInt() == DefaultBaselineParams.thirstThreshold
    check pick["hungerThreshold"].getInt() == DefaultBaselineParams.hungerThreshold
    check pick["shelterStones"].getInt() == DefaultBaselineParams.shelterStones
    check pick["sleepTicks"].getInt() == DefaultBaselineParams.sleepTicks
    check pick["restThreshold"].getInt() == DefaultBaselineParams.restThreshold
    check pick["exploreSteps"].getInt() == DefaultBaselineParams.exploreSteps
    check pick["tieBreakByDistance"].getBool() ==
      DefaultBaselineParams.tieBreakByDistance
    check sweep["grid"].len > 1

  test "forager beats wanderer, and wanderer is not a zero":
    ## Item 25: over 100 seeds of each variant.
    for variant in ["standard", "longnight"]:
      var forager = 0
      var wanderer = 0
      for seed in 1 .. 100:
        let config = testConfig(variant, seed)
        forager += playScripted(config, blForager).achievementsUnlocked()
        wanderer += playScripted(config, blWanderer).achievementsUnlocked()
      check forager > wanderer
      check wanderer >= 1
