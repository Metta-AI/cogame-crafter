## Full native episodes through a loopback provider, with capture on/off parity.
import std/[json, os, osproc, streams, strutils, tempfiles]
import crafter/[sim, decide, prompts, training]

proc run(variant: string, destination: string): string =
  let provider = startProcess("python3", args = [
    currentSourcePath().parentDir() / "native_capture_provider.py"],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    provider.terminate()
    discard provider.waitForExit(5000)
    provider.close()
  let port = provider.outputStream.readLine()
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:" & port)
  putEnv("COWORLD_LLM_MODEL", "native-capture-fixture")
  putEnv("COWORLD_EPISODE_ID", "native-capture-" & variant)
  putEnv("COWORLD_GAME_VERSION", "capture-fixture")
  putEnv("COWORLD_SOURCE_REVISION", repeat('a', 40))
  if destination.len > 0:
    putEnv("COGAME_SAVE_TRAJECTORY_URI", "file://" & destination)
  else:
    delEnv("COGAME_SAVE_TRAJECTORY_URI")
  var config = defaultGameConfig()
  let manifest = parseFile(currentSourcePath().parentDir().parentDir() /
    "coworld_manifest_template.json")
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      config.update($entry["game_config"])
  config.seed = 42
  config.variant = variant
  # Remove only wall pacing for deterministic CPU integration. Rules, horizon,
  # parser, retries, rate guard, simulator and scores remain the native ones.
  config.turnSpacingMs = 0
  config.validate()
  var game = initSimServer(config)
  game.phase = Playing
  game.startRun()
  let selection = promptSelection(newJObject())
  var engine = initDecisionEngine(game, selection)
  engine.seats[0] = SeatPolicy(isLlm: true, registered: true,
    label: "fixture-policy", prompt: "Keep private notes.")
  while game.phase != GameOver:
    if game.waitingForPlan():
      if not game.beginTurn(): break
      let turn = game.turnsPlayed + 1
      let privateView = game.observationJson(includeNotes = true)
      let publicView = game.observationJson(includeNotes = false)
      let decision = engine.turn(game, turn, 0)
      let applied = game.applyDirective(decision.directive, publicView)
      doAssert "PRIVATE_CAPTURE_SENTINEL" notin applied
      engine.trajectory.recordAppliedDecision(turn, privateView, selection,
        engine.seats[0].prompt, game, decision.directive, applied,
        engine.nativeAttempts, engine.seats[0].label)
    game.step()
  doAssert game.endReason == erComplete
  engine.trajectory.finishNativeTrajectory(game)
  result = game.runResultsJson()
  if destination.len > 0:
    let lines = readFile(destination).strip().splitLines()
    doAssert lines.len > 3
    let first = parseJson(lines[0])
    doAssert first["attempts"].len == 2
    doAssert not first["attempts"][0]["accepted"].getBool()
    doAssert first["attempts"][1]["accepted"].getBool()
    let accepted = first["attempts"][1]
    doAssert accepted["prompt"][^1] == %*{"role": "assistant", "content": "{"}
    doAssert accepted["request"]["messages"][^1] == accepted["prompt"][^1]
    doAssert not accepted["response"].getStr().startsWith("{")
    doAssert parseJson(accepted["raw_response"].getStr())["content"][0]["text"] == accepted["response"]
    doAssert accepted["platform_call_id"].getStr().len == 36
    doAssert accepted["behavior_logprobs"].kind == JNull
    let promptAttempts = first["observation"]["prompt_attempts"]
    doAssert promptAttempts.len == 2
    doAssert promptAttempts[1]["attempt_id"] == accepted["attempt_id"]
    doAssert promptAttempts[0]["prompt_template"]["user_sha256"] !=
      promptAttempts[1]["prompt_template"]["user_sha256"]
    doAssert promptAttempts[1]["prompt_template"] == selection.promptMetadata(
      accepted["request"]["system"].getStr(),
      accepted["request"]["messages"][0]["content"].getStr())
    let second = parseJson(lines[1])
    doAssert second["action_status"].getStr() == "fallback"
    doAssert second["selected_attempt_id"].kind == JNull
    doAssert second["attempts"].len == 2
    doAssert not second["attempts"][0]["accepted"].getBool()
    doAssert not second["attempts"][1]["accepted"].getBool()
    let normalized = parseJson(lines[2])
    doAssert normalized["action_status"].getStr() == "rejected"
    doAssert normalized["selected_attempt_id"].kind == JNull
    doAssert not normalized["attempts"][0]["accepted"].getBool()
    doAssert normalized["executed_action"]["actions"] == %*[{"act": "noop"}]
    let terminal = parseJson(lines[^1])
    doAssert terminal["status"].getStr() == "completed"
    doAssert terminal["outcome"] == parseJson(result)
    doAssert terminal["seed_family"].getStr() == "crafter-42"
    doAssert (getFilePermissions(destination) * {fpOthersRead, fpGroupRead}) == {}

let output = createTempDir("crafter-native-capture-", "")
for variant in ["standard", "longnight"]:
  let captured = run(variant, output / (variant & ".jsonl"))
  let ordinary = run(variant, "")
  doAssert captured == ordinary, "capture changed ordinary native game outcomes"
echo "complete native episodes: exact prefill/retries/normalization/fallbacks/private capture and outcome parity passed"
