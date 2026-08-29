## Replay — design note §Tests items 31..36.
##
## Record then re-derive for EVERY end reason, the self-sufficiency of the
## bytes, the incremental terrain digest, `tools/replay_summary.py`'s strict
## UTF-8 JSON, and the committed fixtures' GameVersion sweep.

import std/[json, os, osproc, strutils, unicode, unittest]
import crafter/[sim, driver, directives, baselines, decide, replays, broadcast,
                replay_runtime]
import helpers

proc recordEpisode(rule: EndRule, path: string,
                   say = "", notes = ""): tuple[sim: SimServer, turns: int] =
  ## Records one episode that ends with `rule`, through exactly the writer the
  ## server uses, and returns the settled sim.
  var config = testConfig()
  if rule == edAllUnlocked:
    config.parAchievements = 1
  var sim = initSimServer(config)
  var writer = openReplayWriter(path, config.resolvedJson())
  var turns = 0

  proc writeChat(record: string) =
    if writer.enabled:
      writer.writeChat(tickTime(sim.tickCount), 0, record)
    sim.pushFeedDirective(record)
    sim.pushControlEvents(record)

  proc recordHash() =
    if writer.enabled:
      writer.writeHash(uint32(sim.tickCount), sim.gameHash())

  ## The lobby, then the join and the redacted register record — the same
  ## order the server writes them in.
  while sim.phase == Lobby:
    sim.step()
    recordHash()
  writer.writeJoin(tickTime(sim.tickCount), 0, "forager", 0, "token-0")
  discard sim.addPlayer("forager", 0, "token-0", trusted = true)
  writeChat(registerRecord(0, seatAlias(0), "forager", "scripted", "forager"))

  var faultDetail = ""
  while sim.phase == Playing:
    ## `death` is the only end this episode reaches by PLAYING. Every other
    ## rule is applied through `sim.applyStop` and written as the LOAD-BEARING
    ## stop record — which is precisely the path item 31 exists to check, and
    ## the one the particle-worlds scar was about: a wall-clock (or fault,
    ## or cap) fact cannot be re-derived from sim state, so it is one record
    ## applied by the SAME proc on record and on playback.
    if rule != edDeath and turns == 4:
      if rule == edFault:
        faultDetail = "a deliberate fault"
      sim.applyStop(rule, faultDetail)
      break
    if sim.waitingForPlan():
      if not sim.beginTurn():
        break
      inc turns
      var plan = scriptedPlan(sim, blForager)
      plan.source = dsLlm
      plan.say = say
      plan.notes = notes
      writeChat(sim.applyDirective(plan, sim.observationJson(false)))
    sim.stepTick()
    sim.pending.setLen(0)
    recordHash()
  if sim.phase != GameOver:
    sim.finish(erComplete, edTurnCap)

  ## THE LOAD-BEARING STOP RECORD, for EVERY end reason.
  writeChat(stopRecord(sim.tickCount, sim.endRule,
    (if faultDetail.len > 0: faultDetail else: sim.stopDetail)))
  sim.step()
  recordHash()
  writeChat(resultRecord(sim))
  writer.closeReplayWriter()
  (sim, turns)

proc rederive(path: string): tuple[sim: SimServer, mismatch: int] =
  let data = loadReplay(path)
  var runtime = initReplayRuntime(data, mismatchQuit = false,
                                  gameEventLoggingEnabled = false)
  var guard = 0
  while runtime.sim.tickCount < runtime.player.replayMaxTick() and guard < 4000:
    let before = runtime.sim.tickCount
    runtime.player.stepReplay(runtime.sim)
    if runtime.sim.tickCount == before:
      break
    inc guard
  (runtime.sim, runtime.player.hashMismatchTick)

suite "replay":
  let dir = getTempDir() / "crafter-replay-tests"
  removeDir(dir)
  createDir(dir)

  test "record then re-derive, EVERY end reason":
    ## Item 31, including the STOP TICK (the particle-worlds scar).
    for rule in [edDeath, edAllUnlocked, edTurnCap, edTickCap, edWallClock,
                 edFault]:
      let path = dir / ("end-" & $rule & ".replay")
      let recorded = recordEpisode(rule, path)
      let played = rederive(path)
      check played.mismatch == -1
      check played.sim.tickCount == recorded.sim.tickCount
      check played.sim.gameHash() == recorded.sim.gameHash()
      check played.sim.endRule == recorded.sim.endRule
      check played.sim.endReason == recorded.sim.endReason
      check played.sim.achievementsUnlocked() ==
        recorded.sim.achievementsUnlocked()

  test "the replay is self-sufficient":
    ## Item 32: the bytes alone yield the name, the alias, the policy kind,
    ## the whole config, the seed, the variant, every plan and the result.
    let path = dir / "self.replay"
    discard recordEpisode(edDeath, path, say = "chopping the tree at (30,28)")
    let data = loadReplay(path)
    let config = parseJson(data.configJson)
    for key in ["seed", "variant", "num_agents", "worldSize", "viewSize",
                "regionSize", "turnTicks", "maxTurns", "maxTicks", "dayLength",
                "dayFraction", "mountainThreshold", "maxCows", "maxZombies",
                "maxSkeletons", "foodTicks", "drinkTicks", "energyTicks",
                "regenTicks", "starveTicks", "plantRipenTicks",
                "parAchievements", "maxActionsPerTurn", "macroPrimitiveCap",
                "players", "slots", "fastMode"]:
      check config.hasKey(key)
    ## `tokens` is deliberately absent — a replay is a public artifact.
    check not config.hasKey("tokens")
    check data.joins.len == 1
    check data.joins[0].name == "forager"
    var kinds = 0
    var plans = 0
    var says = 0
    var results = 0
    for chat in data.chats:
      let record = parseJson(chat.message)
      case record{"k"}.getStr()
      of "register":
        inc kinds
        check record{"kind"}.getStr() == "scripted"
        check record{"alias"}.getStr() == "Alpha"
        ## The PROMPT is never written.
        check not record.hasKey("prompt")
      of "directive":
        inc plans
        if record{"say"}.getStr().len > 0: inc says
      of "result":
        inc results
        check record{"results"}{"achievementsOf"}.getInt() == AchievementCount
      else: discard
    check kinds == 1
    check plans > 0
    check says > 0
    check results == 1
    ## Re-simulating from the bytes reproduces the WHOLE world with no fetch.
    let played = rederive(path)
    let reference = generate(config["seed"].getInt(),
                             config["mountainThreshold"].getInt())
    var same = 0
    for slot in 0 ..< WorldCells:
      if played.sim.world.cells[slot] == reference.cells[slot]: inc same
    check same > WorldCells - 200        ## only the cells the cog changed

  test "the incremental terrain digest equals a full fold":
    ## Item 33: the optimisation of §Determinism point 4 is only safe if this
    ## holds after a whole episode of mining and placing.
    let sim = playScripted(testConfig(), blForager)
    check sim.terrainHash == sim.world.terrainDigest()
    check sim.blocksMined + sim.blocksPlaced > 0

  test "replay_summary is strict UTF-8 JSON at every cap":
    ## Item 34: every capped field filled to EXACTLY its cap with 4-byte
    ## emoji.
    var say = ""
    for i in 0 ..< MaxSayRunes:
      say.add("\u{1F9E9}")
    var notes = ""
    for i in 0 ..< MaxNoteRunes:
      notes.add("\u{1F9E9}")
    check say.runeLen == MaxSayRunes
    let path = dir / "emoji.replay"
    discard recordEpisode(edDeath, path, say = say, notes = notes)
    let run = execCmdEx("python3 " & repoRoot() /
      "tools/replay_summary.py " & path)
    check run.exitCode == 0
    ## A STRICT UTF-8 JSON parse, with no lone surrogates.
    let strict = execCmdEx("python3 -c " & quoteShell(
      "import json,sys;" &
      "raw=open(sys.argv[1],'rb').read();" &
      "text=raw.decode('utf-8');" &
      "doc=json.loads(text);" &
      "assert all(not (0xD800 <= ord(c) <= 0xDFFF) for c in text);" &
      "print(doc['protocol'])") & " " & quoteShell(dir / "summary.json"))
    writeFile(dir / "summary.json", run.output)
    let verify = execCmdEx("python3 -c " & quoteShell(
      "import json,sys;" &
      "raw=open(sys.argv[1],'rb').read();" &
      "text=raw.decode('utf-8');" &
      "doc=json.loads(text);" &
      "assert all(not (0xD800 <= ord(c) <= 0xDFFF) for c in text);" &
      "print(doc['protocol'])") & " " & quoteShell(dir / "summary.json"))
    check verify.exitCode == 0
    check verify.output.strip() == "crafter/v1"
    discard strict
    let summary = parseJson(run.output)
    check summary["protocol"].getStr() == "crafter/v1"
    check summary["gameVersion"].getStr() == GameVersion
    check summary["says"].len > 0
    for entry in summary["says"]:
      check entry.getStr().runeLen <= MaxSayRunes

  test "determinism from the replay alone":
    ## Item 35.
    let path = dir / "determinism.replay"
    let recorded = recordEpisode(edDeath, path)
    let first = rederive(path)
    let second = rederive(path)
    check first.sim.gameHash() == second.sim.gameHash()
    check first.sim.tickCount == second.sim.tickCount
    for a in Achievement:
      check first.sim.ledger.unlocked[a] == recorded.sim.ledger.unlocked[a]
      check first.sim.ledger.tick[a] == recorded.sim.ledger.tick[a]

  test "every committed fixture carries the current GameVersion":
    ## Item 36: the starter's sweep over `tests/replays`.
    let fixtures = repoRoot() / "tests" / "replays"
    var swept = 0
    for kind, path in walkDir(fixtures):
      if kind != pcFile or not path.endsWith(".replay"):
        continue
      inc swept
      let data = loadReplay(path)
      check data.gameName == GameName
      check data.gameVersion == GameVersion
      ## And it still re-derives cleanly under the CURRENT rules.
      let played = rederive(path)
      check played.mismatch == -1
    check swept >= 1

  test "half speed is a replay-only crawl":
    ## The fleet-wide 1/2x replay speed: command '5' selects
    ## ReplayHalfSpeedIndex, the chrome shows 0.5, and the step budget spends
    ## one tick every OTHER frame (halfPhase parity) outside lulls.
    var replay = ReplayPlayer()
    replay.speedIndex = 0
    applySpeedCommand(replay.speedIndex, '5')
    check replay.speedIndex == ReplayHalfSpeedIndex
    check replay.replayDisplaySpeed() == 0.5
    ## The integer speed clamps to 1x at 1/2x (live loop safety).
    check replay.replaySpeed() == 1
    replay.skipLulls = false
    replay.halfPhase = false
    check replay.replayStepBudget(0) == 0
    replay.halfPhase = true
    check replay.replayStepBudget(0) == 1
    applySpeedCommand(replay.speedIndex, '+')
    check replay.speedIndex == 0
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex
    ## 1/2x is the floor.
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex

  test "the beat timeline and the lull map draw at full width on frame one":
    let path = dir / "beats.replay"
    discard recordEpisode(edDeath, path)
    let data = loadReplay(path)
    var runtime = initReplayRuntime(data, mismatchQuit = false,
                                    gameEventLoggingEnabled = false)
    runtime.player.buildReplayKeyframes(initSimServer(runtime.config))
    check runtime.player.scanComplete()
    check runtime.player.leadSeries.len >= 2
    check runtime.player.beatEvents.len >= 1
    ## Only the seven documented beat kinds ever reach the scrubber.
    for event in runtime.player.beatEvents:
      check event["k"].getStr() in ["achievement", "nightfall", "daybreak",
                                    "kill", "death", "fallback", "end"]

  removeDir(dir)
