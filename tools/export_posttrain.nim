## Stream private candidate games; shared review owns admission to training.
import std/[json, os, osproc, strutils]
import crafter/[sim, baselines, directives, decide, llm, prompts, evidence]

const OperatorPrompt = "Climb the achievement tree while keeping food, drink, and energy safe."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "standard"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert episodes >= 10 and firstSeed >= 1
  doAssert variant in ["standard", "longnight"]
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + episodes:
      var config = defaultGameConfig()
      config.update($variantConfig)
      config.seed = seed
      config.validate()
      var sim = initSimServer(config)
      sim.phase = Playing
      sim.startRun()
      doAssert sim.beginTurn()
      let family = "crafter-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var decisionId: int
      while sim.phase == Playing:
        let view = sim.observationJson(includeNotes = true)
        let system = systemPrompt(selection)
        let user = userMessage(OperatorPrompt, $view)
        let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
        var observation = copy(view)
        observation["prompt_template"] = selection.promptMetadata(system, user)
        let teacher = sim.scriptedPlan(blForager)
        let proposal = %*{"actions": actionsJson(teacher.actions), "say": teacher.say, "notes": teacher.notes}
        var parsed = parseDirective(proposal, config.maxActionsPerTurn)
        parsed.source = dsScripted
        let executed = %*{"actions": actionsJson(parsed.actions), "say": parsed.say, "notes": parsed.notes}
        let accepted = proposal == executed and parsed.dropped == 0 and parsed.overCap == 0
        let attemptId = $decisionId & "-teacher"
        let attempt = %*{
          "attempt_id": attemptId, "policy": "scripted-forager", "origin": "teacher",
          "inference_mode": "text_action", "prompt": messages,
          "response": $proposal, "parsed_action": proposal, "accepted": accepted,
          "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
          "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")
        }
        let startTick = sim.tickCount
        discard sim.applyDirective(parsed, sim.observationJson(includeNotes = false))
        let queued = primitivesJson(sim.queue)
        while sim.phase == Playing and not sim.waitingForPlan():
          sim.step()
          sim.pending.setLen(0)
        if sim.phase == Playing: discard sim.beginTurn()
        execution.writeLine($(%*{
          "schema_version": 1, "event_type": "plan_execution", "episode_id": episode,
          "decision_id": $decisionId, "source_revision": revision, "visibility": "private",
          "start_tick": startTick, "end_tick": sim.tickCount,
          "queued_primitives": queued, "executed_primitives": primitivesJson(sim.executed),
          "interrupted": sim.lastInterrupted, "truncated": sim.planTruncated,
          "dropped": parsed.dropped, "over_cap": parsed.overCap,
          "unreachable": sim.lastUnreachable, "terminal": sim.phase == GameOver
        }))
        stream.writeLine($(%*{
          "schema_version": "1", "event_type": "decision", "episode_id": episode,
          "decision_id": $decisionId, "decision_index": decisionId,
          "game": "crafter", "game_version": "source-" & revision,
          "source_revision": revision, "seat": "0", "visibility": "private",
          "observation": observation, "prompt": (if accepted: messages else: newJNull()),
          "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
          "executed_action": executed, "action_status": (if accepted: "accepted" else: "fallback"),
          "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
          "terminal": sim.phase == GameOver
        }))
        inc decisionId
      doAssert decisionId > 0 and sim.endReason == erComplete
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "crafter", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed",
        "outcome": parseJson(sim.runResultsJson()),
        "participant_outcomes": {"0": {"score": sim.score()}}
      }))
      runs.add(%*{"seed": seed, "decisions": decisionId, "score": sim.score(),
        "achievements": sim.achievementsUnlocked()})
  finally:
    execution.close()
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "crafter", "variant": variant,
    "source_revision": revision, "teacher": "scripted-forager",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl",
    "runs": runs}) & "\n")
  echo "complete games=", episodes
