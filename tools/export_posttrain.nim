## Export complete scripted Crafter games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [standard|longnight]

import std/[json, os, osproc, strutils]
import crafter/[sim, baselines, directives, decide, llm]

const OperatorPrompt = "Climb the achievement tree while keeping food, drink, and energy safe."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [standard|longnight]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "standard"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["standard", "longnight"]:
    quit("variant must be standard or longnight", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    config.validate()
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startRun()
    var rows: seq[string]
    while sim.phase != GameOver:
      if sim.waitingForPlan():
        if not sim.beginTurn():
          break
        let view = sim.observationJson(includeNotes = true)
        let directive = sim.scriptedPlan(blForager)
        let completion = %*{
          "actions": directive.actions.actionsJson(),
          "say": directive.say,
          "notes": directive.notes
        }
        let parsed = parseDirective(completion, config.maxActionsPerTurn)
        doAssert $parsed.actions.actionsJson() == $directive.actions.actionsJson()
        rows.add($(%*{
          "episode_id": "crafter-" & variant & "-" & $seed,
          "seed": "crafter-" & variant & "-" & $seed,
          "decision_id": sim.turnsPlayed,
          "prompt": [
            {"role": "system", "content": SystemPrompt},
            {"role": "user", "content": userMessage(OperatorPrompt, $view)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "crafter",
          "action_schema_revision": "crafter-directive-v1"
        }))
        discard sim.applyDirective(directive,
          sim.observationJson(includeNotes = false))
      sim.step()
    doAssert sim.phase == GameOver and sim.endReason == erComplete
    doAssert rows.len > 0
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": sim.score(), "achievements": sim.achievementsUnlocked()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "crafter",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-forager",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
