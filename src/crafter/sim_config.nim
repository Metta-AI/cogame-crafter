## `GameConfig` lifecycle: the defaults, `config.update` (the resolved config
## JSON a replay carries and re-derives from), and the validators the design's
## deadlines are chosen to satisfy.
##
## Forked from `coworld-ctf/src/ctf/sim_config.nim`, keeping its validator set:
## whole-second `attempt1Ms` / `retryMs` (curly hands the deadline to
## CURLOPT_TIMEOUT, whose granularity is WHOLE SECONDS, so a config that is
## not a whole number of seconds is not the deadline it claims to be),
## `attempt1Ms + retryMs <= turnBudgetMs`, and a positive
## `wallClockBudgetSeconds`.

import std/[json, strutils]
import sim_types

type
  PlayerSlot* = object
    name*: string

  GameConfig* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    seed*: int
    variant*: string
    numAgents*: int
    minPlayers*: int
    players*: seq[PlayerSlot]
    slots*: seq[int]
    tokens*: seq[string]

    worldSize*: int
    viewSize*: int
    regionSize*: int
    turnTicks*: int
    maxTurns*: int
    maxTicks*: int
    dayLength*: int
    dayFraction*: int
    mountainThreshold*: int
    maxCows*: int
    maxZombies*: int
    maxSkeletons*: int
    foodTicks*: int
    drinkTicks*: int
    energyTicks*: int
    regenTicks*: int
    starveTicks*: int
    plantRipenTicks*: int
    parAchievements*: int
    maxActionsPerTurn*: int
    macroPrimitiveCap*: int

    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int

  ConfigError* = object of ValueError

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    variant: "standard",
    numAgents: 1,
    minPlayers: 1,
    players: @[PlayerSlot(name: "Alpha")],
    slots: @[0],
    tokens: @[],
    worldSize: WorldSize,
    viewSize: ViewSize,
    regionSize: RegionSize,
    turnTicks: 24,
    maxTurns: 56,
    maxTicks: 1344,
    dayLength: 192,
    dayFraction: 128,
    mountainThreshold: 700,
    maxCows: 12,
    maxZombies: 8,
    maxSkeletons: 6,
    foodTicks: 40,
    drinkTicks: 30,
    energyTicks: 50,
    regenTicks: 25,
    starveTicks: 10,
    plantRipenTicks: 120,
    parAchievements: 8,
    maxActionsPerTurn: 12,
    macroPrimitiveCap: 24,
    attempt1Ms: 6000,
    retryMs: 3000,
    turnBudgetMs: 9500,
    turnSpacingMs: 2600,
    wallClockBudgetSeconds: 660,
    lobbyJoinTimeoutTicks: 2400,
    gameOverTicks: 480,
    fastMode: true,
    showPlayerLabels: false,
    model: "",
    maxOutputTokens: 900
  )

proc readInt(node: JsonNode, key: string, target: var int) =
  let value = node{key}
  if value.isNil: return
  case value.kind
  of JInt: target = int(value.getBiggestInt())
  of JFloat: target = int(value.getFloat())
  of JString:
    try: target = parseInt(value.getStr().strip())
    except ValueError: discard
  else: discard

proc readBool(node: JsonNode, key: string, target: var bool) =
  let value = node{key}
  if value.isNil: return
  case value.kind
  of JBool: target = value.getBool()
  of JInt: target = value.getBiggestInt() != 0
  else: discard

proc readStr(node: JsonNode, key: string, target: var string) =
  let value = node{key}
  if value.isNil or value.kind != JString: return
  target = value.getStr()

proc validate*(config: GameConfig) =
  ## The validators the shipped numbers are chosen to satisfy. Each is a
  ## scar: a sub-second deadline is not the deadline it claims to be, and an
  ## unbounded wall clock is an episode the platform silently discards.
  if config.attempt1Ms <= 0 or config.attempt1Ms mod 1000 != 0:
    raise newException(ConfigError,
      "attempt1Ms must be a positive WHOLE number of seconds (curly hands " &
      "the deadline to CURLOPT_TIMEOUT, whose granularity is seconds); got " &
      $config.attempt1Ms)
  if config.retryMs <= 0 or config.retryMs mod 1000 != 0:
    raise newException(ConfigError,
      "retryMs must be a positive WHOLE number of seconds; got " &
      $config.retryMs)
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(ConfigError,
      "attempt1Ms + retryMs must fit inside turnBudgetMs; got " &
      $config.attempt1Ms & " + " & $config.retryMs & " > " &
      $config.turnBudgetMs)
  if config.wallClockBudgetSeconds <= 0:
    raise newException(ConfigError,
      "wallClockBudgetSeconds must be positive")
  if config.numAgents != 1:
    raise newException(ConfigError,
      "crafter is a single-seat game: num_agents must be 1, got " &
      $config.numAgents)
  if config.worldSize != WorldSize or config.viewSize != ViewSize or
      config.regionSize != RegionSize:
    raise newException(ConfigError,
      "worldSize/viewSize/regionSize are pinned at " & $WorldSize & "/" &
      $ViewSize & "/" & $RegionSize)
  if config.turnTicks <= 0 or config.maxTurns <= 0:
    raise newException(ConfigError, "turnTicks and maxTurns must be positive")
  if config.maxTicks != config.maxTurns * config.turnTicks:
    raise newException(ConfigError,
      "maxTicks must equal maxTurns * turnTicks; got " & $config.maxTicks &
      " for " & $config.maxTurns & " x " & $config.turnTicks)
  if config.dayLength <= 0 or config.dayFraction <= 0 or
      config.dayFraction >= config.dayLength:
    raise newException(ConfigError,
      "dayFraction must be positive and strictly below dayLength; got " &
      $config.dayFraction & " of " & $config.dayLength)
  if config.mountainThreshold < 400 or config.mountainThreshold > 900:
    raise newException(ConfigError,
      "mountainThreshold must lie in 400..900 (below it the whole world is " &
      "rock, above it there is no mountain to mine); got " &
      $config.mountainThreshold)
  if config.parAchievements < 0 or config.parAchievements > AchievementCount:
    raise newException(ConfigError,
      "parAchievements must lie in 0.." & $AchievementCount)
  for (name, value) in [("foodTicks", config.foodTicks),
                        ("drinkTicks", config.drinkTicks),
                        ("energyTicks", config.energyTicks),
                        ("regenTicks", config.regenTicks),
                        ("starveTicks", config.starveTicks),
                        ("plantRipenTicks", config.plantRipenTicks),
                        ("maxActionsPerTurn", config.maxActionsPerTurn),
                        ("macroPrimitiveCap", config.macroPrimitiveCap)]:
    if value <= 0:
      raise newException(ConfigError, name & " must be positive; got " & $value)
  for (name, value) in [("maxCows", config.maxCows),
                        ("maxZombies", config.maxZombies),
                        ("maxSkeletons", config.maxSkeletons)]:
    if value < 0 or value > 32:
      raise newException(ConfigError,
        name & " must lie in 0..32 (the creature pools are sized to it); got " &
        $value)

proc update*(config: var GameConfig, configJson: string) =
  ## Applies the resolved config JSON (the runner's, or the one a replay
  ## carries). Unknown keys are ignored; every known key is read through the
  ## tolerant readers above so a stringified integer from a runner never
  ## silently resets a rule constant to its default.
  if configJson.strip().len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(ConfigError, "bad game config JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(ConfigError, "game config must be a JSON object")

  node.readInt("seed", config.seed)
  node.readStr("variant", config.variant)
  node.readInt("num_agents", config.numAgents)
  node.readInt("numAgents", config.numAgents)
  node.readInt("minPlayers", config.minPlayers)
  node.readInt("worldSize", config.worldSize)
  node.readInt("viewSize", config.viewSize)
  node.readInt("regionSize", config.regionSize)
  node.readInt("turnTicks", config.turnTicks)
  node.readInt("maxTurns", config.maxTurns)
  node.readInt("maxTicks", config.maxTicks)
  node.readInt("dayLength", config.dayLength)
  node.readInt("dayFraction", config.dayFraction)
  node.readInt("mountainThreshold", config.mountainThreshold)
  node.readInt("maxCows", config.maxCows)
  node.readInt("maxZombies", config.maxZombies)
  node.readInt("maxSkeletons", config.maxSkeletons)
  node.readInt("foodTicks", config.foodTicks)
  node.readInt("drinkTicks", config.drinkTicks)
  node.readInt("energyTicks", config.energyTicks)
  node.readInt("regenTicks", config.regenTicks)
  node.readInt("starveTicks", config.starveTicks)
  node.readInt("plantRipenTicks", config.plantRipenTicks)
  node.readInt("parAchievements", config.parAchievements)
  node.readInt("maxActionsPerTurn", config.maxActionsPerTurn)
  node.readInt("macroPrimitiveCap", config.macroPrimitiveCap)
  node.readInt("attempt1Ms", config.attempt1Ms)
  node.readInt("retryMs", config.retryMs)
  node.readInt("turnBudgetMs", config.turnBudgetMs)
  node.readInt("turnSpacingMs", config.turnSpacingMs)
  node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readInt("gameOverTicks", config.gameOverTicks)
  node.readBool("fastMode", config.fastMode)
  node.readBool("showPlayerLabels", config.showPlayerLabels)
  node.readStr("model", config.model)
  node.readInt("maxOutputTokens", config.maxOutputTokens)

  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.players = @[]
    for item in players:
      if item.kind == JObject:
        config.players.add(PlayerSlot(name: item{"name"}.getStr("Alpha")))
      elif item.kind == JString:
        config.players.add(PlayerSlot(name: item.getStr()))

  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      if item.kind == JString:
        config.tokens.add(item.getStr())

  let slots = node{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for item in slots:
      if item.kind == JInt:
        config.slots.add(int(item.getBiggestInt()))

  if config.players.len == 0:
    config.players = @[PlayerSlot(name: "Alpha")]
  config.validate()

proc resolvedJson*(config: GameConfig): string =
  ## The config JSON written into the replay header. It carries EVERY rule
  ## constant, the seed, the variant and the real player names, which is what
  ## makes the replay bytes self-sufficient: the viewer re-generates the whole
  ## 64 x 64 world, every ore, every creature and every achievement tick from
  ## this plus the code, with no fetch. `tokens` is deliberately absent — a
  ## replay is a public artifact.
  var players = newJArray()
  for slot in config.players:
    players.add(%*{"name": slot.name})
  var slots = newJArray()
  for slot in config.slots:
    slots.add(%slot)
  $(%*{
    "seed": config.seed,
    "variant": config.variant,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "players": players,
    "slots": slots,
    "worldSize": config.worldSize,
    "viewSize": config.viewSize,
    "regionSize": config.regionSize,
    "turnTicks": config.turnTicks,
    "maxTurns": config.maxTurns,
    "maxTicks": config.maxTicks,
    "dayLength": config.dayLength,
    "dayFraction": config.dayFraction,
    "mountainThreshold": config.mountainThreshold,
    "maxCows": config.maxCows,
    "maxZombies": config.maxZombies,
    "maxSkeletons": config.maxSkeletons,
    "foodTicks": config.foodTicks,
    "drinkTicks": config.drinkTicks,
    "energyTicks": config.energyTicks,
    "regenTicks": config.regenTicks,
    "starveTicks": config.starveTicks,
    "plantRipenTicks": config.plantRipenTicks,
    "parAchievements": config.parAchievements,
    "maxActionsPerTurn": config.maxActionsPerTurn,
    "macroPrimitiveCap": config.macroPrimitiveCap,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels
  })
