## Exact native player evidence, separate from public replays and teacher exports.
import std/[json, options, os]
import bitworld/decision_trajectory
import curly
import sim, directives, prompts, llm

proc initNativeTrajectory*(config: GameConfig): DecisionTrajectory =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0:
    return nil
  newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"), "crafter-" & $config.seed,
    "crafter", getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"))

proc directiveAction*(directive: Directive): JsonNode =
  %*{"actions": actionsJson(directive.actions), "say": directive.say,
    "notes": directive.notes}

proc nativeAttempt*(policy: string, turn, attempt: int, body: string): DecisionAttempt =
  result = newDecisionAttempt("turn-" & $turn & "-attempt-" & $attempt, policy, aoModel)
  result.request = parseJson(body)
  result.prompt = %*[{"role": "system", "content": result.request["system"]}]
  for message in result.request["messages"]:
    result.prompt.add(copy(message))
  result.decoder = newJObject()
  for key, value in result.request:
    if key notin ["model", "system", "messages", "anthropic_version"]:
      result.decoder[key] = copy(value)

proc receiveNativeResponse*(attempt: var DecisionAttempt, response: Response,
    transportError: string, latencyMs: int) =
  attempt.rawResponse = %response.body
  attempt.latencyMs = some(latencyMs.float)
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    let value = response.headers[header]
    if value.len > 0:
      case field
      of "call": attempt.platformCallId = some(value)
      of "model": attempt.modelIdentity = some(value)
      of "tokenizer": attempt.tokenizerIdentity = some(value)
      of "template": attempt.chatTemplateSha256 = some(value)
  if transportError.len > 0 or response.code < 200 or response.code >= 300:
    return
  let payload = parseJson(response.body)
  if payload.hasKey("model") and payload["model"].kind == JString:
    attempt.model = some(payload["model"].getStr())
  if payload.hasKey("stop_reason") and payload["stop_reason"].kind == JString:
    attempt.stopReason = some(payload["stop_reason"].getStr())
  let usage = payload{"usage"}
  if not usage.isNil and usage.hasKey("input_tokens") and usage["input_tokens"].kind == JInt:
    attempt.inputTokens = some(payload["usage"]["input_tokens"].getInt())
  if not usage.isNil and usage.hasKey("output_tokens") and usage["output_tokens"].kind == JInt:
    attempt.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  var receivedText = ""
  if payload.hasKey("content") and payload["content"].kind == JArray:
    for contentBlock in payload["content"]:
      if contentBlock{"type"}.getStr() == "text" and contentBlock.hasKey("text") and
          contentBlock["text"].kind == JString:
        receivedText.add(contentBlock["text"].getStr())
  # Keep the generated suffix exactly. The supplied assistant "{" stays in
  # the captured prompt; textOf's parser reconstruction is never a teacher label.
  attempt.response = %receivedText
  let sampling = payload{"sampling_evidence"}
  if not sampling.isNil and sampling.kind != JNull:
    var promptTokens, responseTokens: seq[int]
    for token in sampling["prompt_token_ids"]: promptTokens.add(token.getInt())
    for token in sampling["completion_token_ids"]: responseTokens.add(token.getInt())
    attempt.promptTokenIds = some(promptTokens)
    attempt.sampledTokenIds = some(responseTokens)
    if sampling["behavior_log_probs"].kind != JNull:
      var probabilities: seq[float]
      for value in sampling["behavior_log_probs"]: probabilities.add(value.getFloat())
      attempt.behaviorLogprobs = some(probabilities)
    attempt.stopReason = some(sampling["stop_reason"].getStr())

proc recordAppliedDecision*(trajectory: DecisionTrajectory, turn: int,
    observation: JsonNode, selection: PromptSelection, operatorPrompt: string,
    sim: SimServer, directive: Directive, appliedRecord: string,
    evidence: seq[DecisionAttempt], policy: string) =
  if trajectory.isNil:
    return
  let applied = parseJson(appliedRecord)
  doAssert applied["actions"] == actionsJson(directive.actions)
  doAssert sim.notes == directive.notes
  let action = directive.directiveAction()
  var attempts = evidence
  var selected = none(string)
  var status = asAccepted
  var fallback = none(string)
  case directive.source
  of dsLlm:
    doAssert attempts.len > 0 and attempts[^1].parsedAction == action
    if attempts[^1].accepted:
      selected = some(attempts[^1].attemptId)
    else:
      status = asRejected
  of dsFallback:
    status = asFallback
    fallback = some("scripted-forager")
    for attempt in attempts.mitems:
      attempt.accepted = false
  of dsScripted:
    # A native scripted action is observed evidence, not an approved model label.
    var attempt = newDecisionAttempt("applied-scripted", policy, aoUnknown)
    attempt.response = %($action)
    attempt.parsedAction = action
    attempt.accepted = true
    selected = some(attempt.attemptId)
    attempts.add(attempt)
  var privateView = copy(observation)
  privateView["prompt_template"] = selection.promptMetadata(
    systemPrompt(selection), userMessage(operatorPrompt, $observation))
  privateView["prompt_attempts"] = newJArray()
  for attempt in attempts:
    if attempt.origin == aoModel:
      privateView["prompt_attempts"].add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": selection.promptMetadata(
          attempt.request["system"].getStr(),
          attempt.request["messages"][0]["content"].getStr())})
  trajectory.recordDecision("turn-" & $turn, "0", privateView, attempts,
    selected, action, status, fallbackOrigin = fallback)

proc finishNativeTrajectory*(trajectory: DecisionTrajectory, sim: SimServer) =
  if trajectory.isNil:
    return
  let outcome = parseJson(sim.runResultsJson())
  trajectory.finish(if sim.endReason == erComplete: esCompleted else: esFailed,
    outcome, %*{"0": {"score": outcome["scores"][0]}})
  trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
