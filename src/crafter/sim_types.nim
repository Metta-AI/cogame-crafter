## Consts, wire types and the closed enums the whole game is written against.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`, keeping its discipline:
## `GameVersion` gates replay compatibility and carries a PREPEND-ONLY
## changelog comment (`tools/ci/check_gameversion.sh` diffs the headline, not
## the digits); `TargetFps` is the one tick rate; the flatty wire types'
## FIELD ORDER IS SACRED — a reordered field silently re-interprets every
## recorded keyframe.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints).
## `MaxSayRunes` and `MaxNoteRunes` are RE-PINNED in this fork (the starter's
## 10-rune shout and 160-rune note are a paintball shout and a paintball
## note): a cog narrating a survival run needs a sentence, and a cog carrying
## its own map and tech plan between turns needs more than 160 runes.
## `ShoutMaxChars` is deleted with the shout mechanic.
##
## INTEGER ARITHMETIC ONLY. There is no floating point in this module, in
## `world.nim`, `agent.nim`, `creatures.nim`, `achievements.nim`,
## `sim_state.nim`, `driver.nim` or `baselines.nim`, and
## `tests/test_crafter_sim.nim` greps for it. That is what makes the native
## <-> wasm hash chain exact by construction.

import std/[strutils, unicode]

const
  GameName* = "crafter"

  GameVersion* = "1"
    ## GV1 (first rules): ONE COG, 64x64 SEEDED WILDERNESS, 22 ACHIEVEMENTS.
    ## The integer value-noise generator and its five-step playability
    ## post-pass, the 9x9 egocentric window, the seventeen primitives, the two
    ## macros, four vitals, day/night, cows/zombies/skeletons/arrows, and the
    ## lexicographic achievements-then-survival score. Nothing is obsoleted —
    ## this is the first version of these rules.

  TargetFps* = 24
    ## The one tick rate. Replay times are derived from it, the lobby
    ## countdown counts in it, and the static viewer plays back against it.
  ReplayFps* = TargetFps
  PlaybackSpeeds* = [1, 2, 4, 8, 16, 32]

  WorldSize* = 64
    ## A 64 x 64 grid of cells indexed (x, y), x the column 0..63 west->east
    ## and y the row 0..63 north->south. The outermost ring is BEDROCK, so the
    ## cog can never leave the world and no generator needs an out-of-bounds
    ## branch.
  WorldCells* = WorldSize * WorldSize      ## 4096 — `results.cellsTotal`
  ViewSize* = 9
    ## The egocentric window: 9 x 9 world cells centred on the cog, in WORLD
    ## orientation (never rotated to the heading — Crafter's own convention).
  RegionSize* = 16
    ## The known map downsampled 4 x 4 into 16 x 16 notable-terrain glyphs.
  RegionScale* = WorldSize div RegionSize  ## 4
  NoiseStride* = 8                         ## the value-noise lattice stride
  MaxLandmarks* = 24
  BoardCellPx* = 24
    ## The board's native tile size: 64 x 24 = 1536 x 1536 px.
  BoardPx* = WorldSize * BoardCellPx
  CameraCells* = 15
    ## The follow-cam window. `zoom = worldSize / cellsAcross = 64 / 15`, and
    ## the appended game block sets exactly that once per board.
  VitalMax* = 9
  InventoryMax* = 9

  MaxSayRunes* = 160            ## the cog thinking out loud, in RUNES.
  MaxNoteRunes* = 400           ## the private scratchpad, in RUNES.
  MaxPolicyLabelRunes* = 64     ## `register.policy` cap, in RUNES.
  MaxFallbackDetailRunes* = 200 ## `fallback.detail` cap, in RUNES.
  MaxDirectiveRunes* = 4000     ## whole serialized `directive` record cap.
  MaxPromptRunes* = 4000        ## PLAYER_PROMPT transport cap.
  MaxStopDetailRunes* = 200     ## `results.stopDetail` cap, in RUNES.
  MaxReplyBytes* = 4096         ## bytes read from the provider before parsing.

  MaxPlayers* = 1
    ## num_agents is fixed at 1 in every variant and in the cert fixture.
    ## Crafter and Craftax are single-agent benchmarks and a second cog would
    ## change the achievement semantics entirely.

type
  Terrain* = enum
    ## The closed terrain enum. A cell holds exactly one terrain and at most
    ## one creature.
    tGrass = "grass"
    tSand = "sand"
    tWater = "water"
    tStone = "stone"
    tPath = "path"
    tTree = "tree"
    tCoal = "coal"
    tIron = "iron"
    tDiamond = "diamond"
    tLava = "lava"
    tBedrock = "bedrock"
    tTable = "table"
    tFurnace = "furnace"
    tSapling = "sapling"
    tRipePlant = "ripe_plant"

  Facing* = enum
    ## World frame: up = -y, down = +y, left = -x, right = +x.
    fUp = "up"
    fRight = "right"
    fDown = "down"
    fLeft = "left"

  Primitive* = enum
    ## Exactly Crafter's seventeen, by name. One primitive is one tick, and
    ## an inapplicable primitive is a no-op that STILL COSTS ITS TICK.
    pNoop = "noop"
    pMoveLeft = "move_left"
    pMoveRight = "move_right"
    pMoveUp = "move_up"
    pMoveDown = "move_down"
    pDo = "do"
    pSleep = "sleep"
    pPlaceStone = "place_stone"
    pPlaceTable = "place_table"
    pPlaceFurnace = "place_furnace"
    pPlacePlant = "place_plant"
    pMakeWoodPickaxe = "make_wood_pickaxe"
    pMakeStonePickaxe = "make_stone_pickaxe"
    pMakeIronPickaxe = "make_iron_pickaxe"
    pMakeWoodSword = "make_wood_sword"
    pMakeStoneSword = "make_stone_sword"
    pMakeIronSword = "make_iron_sword"

  Resource* = enum
    rWood = "wood"
    rStone = "stone"
    rCoal = "coal"
    rIron = "iron"
    rDiamond = "diamond"
    rSapling = "sapling"

  Tool* = enum
    toWoodPickaxe = "wood_pickaxe"
    toStonePickaxe = "stone_pickaxe"
    toIronPickaxe = "iron_pickaxe"
    toWoodSword = "wood_sword"
    toStoneSword = "stone_sword"
    toIronSword = "iron_sword"

  Vital* = enum
    vHealth = "health"
    vFood = "food"
    vDrink = "drink"
    vEnergy = "energy"

  Achievement* = enum
    ## The canonical Crafter list, in the canonical order. This ordering is
    ## `achievementIds` in `results`, the order of the viewer's checklist and
    ## the order of the `locked` list in the observation.
    aCollectWood = "collect_wood"
    aPlaceTable = "place_table"
    aEatCow = "eat_cow"
    aCollectSapling = "collect_sapling"
    aCollectDrink = "collect_drink"
    aMakeWoodPickaxe = "make_wood_pickaxe"
    aMakeWoodSword = "make_wood_sword"
    aPlacePlant = "place_plant"
    aDefeatZombie = "defeat_zombie"
    aCollectStone = "collect_stone"
    aPlaceStone = "place_stone"
    aEatPlant = "eat_plant"
    aDefeatSkeleton = "defeat_skeleton"
    aMakeStonePickaxe = "make_stone_pickaxe"
    aMakeStoneSword = "make_stone_sword"
    aWakeUp = "wake_up"
    aPlaceFurnace = "place_furnace"
    aCollectCoal = "collect_coal"
    aCollectIron = "collect_iron"
    aMakeIronPickaxe = "make_iron_pickaxe"
    aMakeIronSword = "make_iron_sword"
    aCollectDiamond = "collect_diamond"

  CreatureKind* = enum
    ckCow = "cow"
    ckZombie = "zombie"
    ckSkeleton = "skeleton"
    ckArrow = "arrow"

  DeathCause* = enum
    ## Closed enum; `dcNone` when the episode did not end in death.
    dcNone = "none"
    dcZombie = "zombie"
    dcSkeleton = "skeleton"
    dcArrow = "arrow"
    dcLava = "lava"
    dcStarvation = "starvation"
    dcThirst = "thirst"
    dcExhaustion = "exhaustion"

  EndReason* = enum
    ## `results.reason` — exactly these three values are legal.
    erComplete = "complete"
    erDeadline = "deadline"
    erFault = "fault"

  EndRule* = enum
    ## `results.endRule` — which of the end conditions fired.
    edNone = ""
    edDeath = "death"
    edAllUnlocked = "allUnlocked"
    edTurnCap = "turnCap"
    edTickCap = "tickCap"
    edWallClock = "wallClock"
    edFault = "fault"

  Phase* = enum
    Lobby
    Playing
    GameOver

  Creature* = object
    ## FLATTY WIRE TYPE — field order is sacred. Creatures live in a single
    ## stable array ordered by (spawnTick, spawnY, spawnX); that order is the
    ## resolution order and it never changes for a living creature.
    kind*: CreatureKind
    x*, y*: int
    hp*: int
    facing*: Facing        ## an arrow's direction of flight
    lastAct*: int          ## last tick this creature moved / attacked / shot
    alive*: bool

const
  AchievementCount* = 22
  TerrainGlyphs*: array[Terrain, char] =
    ['.', ',', '~', '#', '=', 'T', 'c', 'i', 'D', '!', 'B', 't', 'f', 'p', 'Y']
  CreatureGlyphs*: array[CreatureKind, char] = ['U', 'Z', 'K', '^']
  CogGlyph* = '@'
  UnseenGlyph* = '?'

  Facings* = [fUp, fRight, fDown, fLeft]
    ## 4-adjacency in the FIXED order up, right, down, left. The BFS's
    ## neighbour order, so a path is unique for a given known map.
  FacingDx*: array[Facing, int] = [0, 1, 0, -1]
  FacingDy*: array[Facing, int] = [-1, 0, 1, 0]

  RegionPriority* = [tDiamond, tIron, tCoal, tLava, tWater, tTree, tStone,
                     tTable, tFurnace, tSapling, tRipePlant, tPath, tSand,
                     tGrass]
    ## `D > i > c > ! > ~ > T > # > t > f > p > Y > = > , > .`

proc walkable*(terrain: Terrain): bool =
  ## Can the cog step into it? LAVA IS WALKABLE — stepping in is how a cog
  ## dies, not something the physics prevents.
  terrain in {tGrass, tSand, tPath, tLava}

proc glyphOf*(terrain: Terrain): char = TerrainGlyphs[terrain]

proc placeableOver*(terrain: Terrain): bool =
  ## What `place_stone` may cover.
  terrain in {tGrass, tSand, tPath, tWater, tLava}

proc buildableOver*(terrain: Terrain): bool =
  ## What `place_table` / `place_furnace` may cover.
  terrain in {tGrass, tSand, tPath}

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened. A byte slice can cut a codepoint
  ## in half; a replay written that way renders in a browser and then fails a
  ## strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## What the cog says out loud: newlines collapsed so one record stays one
  ## line, then capped at MaxSayRunes on a RUNE boundary.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxSayRunes)

proc sanitizeNote*(text: string): string =
  ## The cog's private scratchpad, echoed back to this seat only next turn.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc mix64*(a, b, c, d: int): uint64 =
  ## splitmix64 over the four mixed words. THE ONLY source of randomness in
  ## this game, and it is a pure HASH, not a consumed stream: the world of
  ## seed `s` is the same world no matter how the cog plays it.
  var x = 0x9E3779B97F4A7C15'u64
  for value in [a, b, c, d]:
    x = x xor cast[uint64](int64(value))
    x = x * 0xBF58476D1CE4E5B9'u64
    x = x xor (x shr 30)
    x = x * 0x94D049BB133111EB'u64
    x = x xor (x shr 27)
  x = x xor (x shr 31)
  x

proc mix64*(a, b, c: int): uint64 = mix64(a, b, c, 0)

proc moveFacing*(primitive: Primitive): tuple[ok: bool, dir: Facing] =
  ## The facing a `move_<dir>` primitive names.
  case primitive
  of pMoveUp: (true, fUp)
  of pMoveDown: (true, fDown)
  of pMoveLeft: (true, fLeft)
  of pMoveRight: (true, fRight)
  else: (false, fUp)

proc parseFacing*(text: string): tuple[ok: bool, dir: Facing] =
  ## Case-insensitive, accepting the word, the initial and the compass letter.
  case text.strip().toLowerAscii()
  of "up", "u", "n", "north": (true, fUp)
  of "down", "d", "s", "south": (true, fDown)
  of "left", "l", "w", "west": (true, fLeft)
  of "right", "r", "e", "east": (true, fRight)
  else: (false, fUp)

proc parsePrimitive*(text: string): tuple[ok: bool, primitive: Primitive] =
  ## Lower-cased and `-` -> `_` normalised before matching.
  let key = text.strip().toLowerAscii().replace("-", "_")
  for primitive in Primitive:
    if $primitive == key:
      return (true, primitive)
  (false, pNoop)
