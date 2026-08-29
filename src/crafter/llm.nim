## Claude-backed single-seat command. A policy is just a prompt: the game
## server composes the seat's partially observed view plus that seat's
## PLAYER_PROMPT and asks Claude what the cog does for the next twelve ticks.
##
## Forked from `coworld-ctf/src/ctf/llm.nim` behaviour for behaviour — the
## credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because
## they are all scar tissue from real hosted failures.
##
## Crafter is a SINGLE-SEAT game, so the starter's one-parallel-batch-per-turn
## machinery (`curly.makeRequests`) carries a batch of ONE and is otherwise
## untouched. At most one request is ever in flight.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils],
  bitworld/runtime,
  curly,
  sim_types, sim_config

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  ReplyPrefill* = "{"
    ## The assistant-turn prefill. Re-prefixed before parsing, and guarded
    ## against a provider that echoes it.
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "crafter llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. `us.anthropic.claude-sonnet-4-6` is DELIBERATELY NOT A CANDIDATE:
  ## it times out on every sidecar call (cogame-raid round 2, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "crafter llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "crafter llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "crafter llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "crafter llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  ## THE ASSISTANT-TURN PREFILL OF `{`. Both Anthropic Messages and Bedrock
  ## invoke accept a trailing assistant turn, and it is what stops a model
  ## from spending the whole token budget on preamble before the JSON (the
  ## procgen 0.1.2 "cut off at max_tokens" scar — the fix is the prefill,
  ## never a bigger cap). `textOf` re-prefixes it before parsing and guards a
  ## provider that echoes it back.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user},
                 {"role": "assistant", "content": ReplyPrefill}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " &
      detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  ## Cap the read at MaxReplyBytes before parsing: a provider body is
  ## arbitrary bytes and the reply schema bounds what may be read.
  let payload = parseJson(
    if response.body.len > 4 * MaxReplyBytes:
      response.body[0 ..< 4 * MaxReplyBytes]
    else:
      response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  ## Re-prefix the prefill, unless the provider echoed it back.
  if not result.strip().startsWith(ReplyPrefill):
    result = ReplyPrefill & result
  if result.len > MaxReplyBytes:
    result = result.truncateRunes(MaxReplyBytes)
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are one cog alone in a 64x64 wilderness. You can see a 9x9 square around
yourself and nothing else. You are hungry, thirsty and tired, and monsters come
out at night. There are 22 things you have never done, and the ONLY thing that
is scored is how many of them you do before you die.

WHAT YOU GET EACH TURN
- "view": 9 rows of 9 characters, the world around you, NORTH UP. You are the @
  in the middle. Row 0 is north, the last row is south.
- "region": the whole 64x64 world you have explored, squashed 4x4 into 16x16.
  ? means you have never been there.
- "nearest": exact x,y of the closest thing of each kind you have SEEN. This is
  what you aim "goto" at.
- "agent": your x, y, facing, and your four bars: health, food, drink, energy,
  each 0 to 9. Any bar at 0 eats your health until you die.
- "achievements": what you have done and what is LEFT. The list of what is left
  is your to-do list. Work down it.

GLYPHS
  .  grass   ,  sand    ~  water    #  stone    =  cave floor   T  tree
  c  coal    i  iron    D  diamond  !  LAVA (walking into it kills you instantly)
  t  table   f  furnace p  sapling  Y  ripe plant  B  world edge
  U  cow     Z  zombie  K  skeleton ^  arrow    @  you    ?  never seen

THE TECH TREE (each step needs the one before it)
  chop a tree            -> wood
  place_table (1 wood)   -> you can now craft, but only while STANDING NEXT TO IT
  make_wood_pickaxe (1 wood)      make_wood_sword (1 wood)
  mine stone (needs wood pickaxe) -> stone
  make_stone_pickaxe (1 wood + 1 stone)   make_stone_sword (1 wood + 1 stone)
  place_furnace (1 stone)
  mine coal (wood pickaxe), mine iron (STONE pickaxe)
  make_iron_pickaxe / make_iron_sword (1 wood + 1 coal + 1 iron, needs table
    AND furnace both within one cell of you)
  mine diamond (needs IRON pickaxe)

STAYING ALIVE
  drink: face water, "do". food: kill a cow ("do" it 2-4 times) or eat a ripe
  plant. energy: "sleep". Sleeping outdoors is how cogs die - wall yourself in
  with place_stone first, or dig into a hillside and seal the hole.
  Zombies spawn at night on grass and burn up at dawn. Skeletons live in caves
  and shoot arrows down straight lines.

WHAT YOU SEND
One JSON object with up to 12 actions. They run one per tick, in order, up to 24
ticks, then you are asked again. ANY hit you take ENDS YOUR TURN EARLY and
throws away the rest of your plan - so do not plan 24 ticks of mining with a
zombie on screen.
  {"act":"goto","x":35,"y":25}   WALK THERE. Shortest path through ground you
      have already seen; it will not path through water, lava, rock or the
      unknown. It stops ON the target if you can stand there, otherwise NEXT TO
      it, FACING it - which is exactly what you want before "do".
  {"act":"move","dir":"up","n":4}  step up to 4 times north. "move" also TURNS
      you: moving into a wall just turns you to face it.
  {"act":"do","n":4}   use the cell you are FACING, 4 times: chop, mine, drink,
      or hit whatever is standing there.
  {"act":"sleep","n":12}  sleep 12 ticks. +1 energy a tick. A zombie that bites
      you while asleep does 5 damage, not 2.
  {"act":"place_stone"} {"act":"place_table"} {"act":"place_furnace"}
  {"act":"place_plant"} {"act":"make_wood_pickaxe"} ... all 17 by name.

HOW YOU ARE SCORED
Only the count of achievements. Surviving longer is the tie-break, and only the
tie-break. A cog that hides in a hole all episode scores almost nothing.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the
character { and end with }. No prose, no markdown, no code fences.
{"actions":[{"act":"goto","x":35,"y":25},{"act":"do","n":4}],"say":"<=160 chars","notes":"<=400 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## observation. The observation is built server-side (see sim_state.nim).
  operatorBlock(operatorPrompt) & viewJson
