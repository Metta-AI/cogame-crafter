## Headless numeric training against Crafter's published simulator and driver.
## nim c -d:release --path:src -o:/tmp/crafter-train-bridge tools/train_bridge.nim

import std/[hashes, json, os]
import crafter/[sim, baselines, directives, decide, driver, llm]

const
  OperatorPrompt = "Climb the achievement tree while keeping food, drink, and energy safe."
  PrimitiveStart = 2
  MoveStart = PrimitiveStart + ord(akMakeIronSword) + 1
  GotoStart = MoveStart + 4
  ChoiceCount = GotoStart + NearestTerrains.len
  Glyphs = ".,~#=TciD!BtfpYUZK^@?"

var
  game: SimServer
  decisionId: int
  variant: string
  manifestPath: string

proc glyphIndex(ch: char): int =
  for i, glyph in Glyphs:
    if glyph == ch: return i
  raise newException(ValueError, "unknown Crafter glyph: " & $ch)

proc values(view: JsonNode): JsonNode =
  result = newJArray()
  for name in ["standard", "longnight"]:
    result.add(%(if variant == name: 1 else: 0))
  for name in ["turn", "tick"]: result.add(view[name])
  for name in ["day", "ticks_to_phase_change", "ticks_left", "turns_left"]:
    result.add(view["time"][name])
  result.add(%(if view["time"]["phase"].getStr() == "day": 1 else: 0))
  let agent = view["agent"]
  for name in ["x", "y", "health", "food", "drink", "energy"]:
    result.add(agent[name])
  for facing in Facings:
    result.add(%(if agent["facing"].getStr() == $facing: 1 else: 0))
  result.add(%(if agent["asleep"].getBool(): 1 else: 0))
  result.add(%glyphIndex(agent["ahead"]["glyph"].getStr()[0]))
  for resource in Resource: result.add(view["inventory"][$resource])
  for tool in Tool:
    result.add(%(if view["tools"][$tool].getBool(): 1 else: 0))
  for name in ["table", "furnace"]:
    result.add(%(if view["near"][name].getBool(): 1 else: 0))
  for achievement in Achievement:
    var unlocked = false
    for name in view["achievements"]["unlocked"]:
      if name.getStr() == $achievement: unlocked = true
    result.add(%(if unlocked: 1 else: 0))
  for row in view["view"]:
    doAssert row.getStr().len == ViewSize
    for glyph in row.getStr(): result.add(%glyphIndex(glyph))
  for row in view["region"]:
    doAssert row.getStr().len == RegionSize
    for glyph in row.getStr(): result.add(%glyphIndex(glyph))
  for terrain in NearestTerrains:
    let spot = view["nearest"][$terrain]
    result.add(%(if spot.kind == JNull: 0 else: 1))
    for name in ["x", "y", "d"]:
      result.add(if spot.kind == JNull: %0 else: spot[name])
  for name in ["truncated", "dropped", "unreachable"]:
    let value = view["last_plan"][name]
    result.add(if value.kind == JBool: %(if value.getBool(): 1 else: 0) else: value)

proc candidates(view: JsonNode): JsonNode =
  result = newJArray()
  for choice in 0 ..< GotoStart: result.add(%*{"choice": choice})
  for terrain in NearestTerrains:
    if view["nearest"][$terrain].kind == JNull: result.add(newJNull())
    else: result.add(%*{"choice": result.len})

proc currentDecision(): JsonNode =
  let view = game.observationJson(includeNotes = true)
  %*{"kind": "decision", "game": "crafter", "decision_id": decisionId,
    "seat": 0, "engine_seat": 0, "turn": game.turnsPlayed,
    "semantic_view": view, "inbox": [],
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(OperatorPrompt, $view)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0,
        "maximum": ChoiceCount - 1}}, "required": ["choice"]},
    "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == 1
  let manifest = parseFile(manifestPath)
  var selected = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: selected = entry["game_config"]
  doAssert selected.kind == JObject
  var config = defaultGameConfig()
  config.update($selected)
  config.variant = variant
  config.seed = int(hash(command["seed"].getStr()) and hash(high(int)))
  config.validate()
  game = initSimServer(config)
  game.phase = Playing
  game.startRun()
  doAssert game.beginTurn()
  decisionId = 0
  currentDecision()

proc planFor(choice: int, view: JsonNode): JsonNode =
  if choice < 2:
    let baseline = if choice == 0: blForager else: blWanderer
    return %*{"actions": actionsJson(game.scriptedPlan(baseline).actions)}
  if choice < MoveStart:
    return %*{"actions": [{"act": $ActionKind(choice - PrimitiveStart)}]}
  if choice < GotoStart:
    return %*{"actions": [{"act": "move", "dir": $Facings[choice - MoveStart], "n": 4}]}
  let spot = view["nearest"][$NearestTerrains[choice - GotoStart]]
  %*{"actions": [{"act": "goto", "x": spot["x"], "y": spot["y"]}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let candidate = parseJson(command["response"].getStr())
  let choice = candidate["choice"].getInt()
  let view = game.observationJson(includeNotes = true)
  doAssert choice in 0 ..< ChoiceCount and candidates(view)[choice].kind != JNull
  let directive = parseDirective(planFor(choice, view), game.config.maxActionsPerTurn)
  discard game.applyDirective(directive, game.observationJson(includeNotes = false))
  while game.phase == Playing and not game.waitingForPlan():
    game.step()
    game.pending.setLen(0)
  if game.phase == Playing: discard game.beginTurn()
  inc decisionId
  let observation = if game.phase == GameOver:
    %*{"kind": "terminal", "scores": {"0": game.score()},
      "utilities": {"0": 2.0 * float(game.score()) /
        float(10_000 * AchievementCount + game.config.maxTicks) - 1.0}}
    else: currentDecision()
  %*{"kind": "accepted", "action": candidate, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: crafter-train-bridge MANIFEST [standard|longnight]", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "longnight"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": %*{"decision_id": decisionId,
        "values": values(game.observationJson(includeNotes = true)),
        "actions": candidates(game.observationJson(includeNotes = true))}
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
