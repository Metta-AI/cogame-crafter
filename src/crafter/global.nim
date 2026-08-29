## The board compositor: the sprite pools, the install-time bakes and the
## sprite-protocol packet the viewer's `broadcast_core.js` composites.
##
## Forked from `coworld-ctf/src/ctf/global.nim` with its three named edits:
##
## 1. THE BOARD IS A 64 x 64 CELL GRID, NOT A PIXEL ARENA. Placements are
##    emitted in cell space multiplied by `CellPx`; the starter's raycast fov
##    cache and shadowcasting are DELETED and replaced by the 9 x 9 window's
##    boolean mask plus the known-map mask, which the viewer draws as the
##    two-level fog wash.
## 2. TERRAIN, CREATURE AND ARROW POOLS. `TerrainBase` is a tile layer
##    redrawn INCREMENTALLY on mutation, never per-frame from scratch;
##    `CreatureBase` is sized to 32 and `ArrowBase` to 16, filled in the
##    stable creature order and emitted incrementally like the starter's other
##    object families.
## 3. BAKED TERRAIN BED. `arena_floor.png` is tiled and recoloured per terrain
##    at install with pixie, exactly the way the starter bakes endzone paint,
##    so the per-frame cost is the cog, <= 26 creatures, <= 16 arrows, the two
##    fog masks and the overlays — never 4096 tile draws.
##
## Every asset is `staticRead` at compile time rather than read off disk, so
## the wasm module carries its own art and a missing preload can never leave
## the hosted viewer with a blank board.

import std/[strutils, tables]
import pixie, chroma, vmath
import bitworld/spriteprotocol
import sim

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved sprite id whose LABEL carries the broadcast chrome JSON on the
    ## binary channel. Kept off the drawable sprite map by the client and fed
    ## straight to `onText`.
  CellPx* = BoardCellPx
  MapLayerId* = 0

  FloorArt = staticRead("../../data/arena_floor.png")
  WallArtH = staticRead("../../client/art/walls/wall_h.jpg")
  WallArtV = staticRead("../../client/art/walls/wall_v.jpg")
  ## THE BOARD CHARACTER IS A NANO-BANANA RENDER OF THE SOFTMAX COG, one
  ## sprite per facing, not a procedural rig: `scripts/art/source/*.png` is a
  ## `gemini-2.5-flash-image` render anchored on the shipped
  ## `data/soldier_red.png` master, keyed and split by
  ## `scripts/art/split_cog_sheet.py`. The four facings share one style and
  ## the visor makes the heading readable at board scale WITHOUT a label.
  CogArt: array[Facing, string] = [
    staticRead("../../data/art/cog_north.png"),
    staticRead("../../data/art/cog_east.png"),
    staticRead("../../data/art/cog_south.png"),
    staticRead("../../data/art/cog_west.png")]
  ## The cow, the zombie and the skeleton are the SAME nano-banana sheet
  ## (`scripts/art/source/crafter_cast_sheet.png`), so the whole cast reads as
  ## one style at board scale. The arrow is a 3 px procedural dart — a render
  ## of a dart at 24 px is a smudge.
  CreatureArt: array[ckCow .. ckSkeleton, string] = [
    staticRead("../../data/art/cow.png"),
    staticRead("../../data/art/zombie.png"),
    staticRead("../../data/art/skeleton.png")]

  ## Sprite ids. FOG AND NIGHT ARE FOLDED INTO THE TERRAIN SPRITE, not drawn
  ## as extra objects: a 4096-cell board cannot afford three object layers,
  ## and the compositor's per-frame cost is one `drawImage` per OBJECT. One
  ## object per cell it is, and the wash level picks which of the four baked
  ## variants that object points at.
  WashDay = 0                     ## inside the 9 x 9 window, daylight
  WashDayDim = 1                  ## remembered, outside the window, daylight
  WashNight = 2
  WashNightDim = 3
  WashCount = 4
  SidTerrain = 100                ## + wash * 32 + ord(Terrain)
  SidTerrainAlt = 300             ## + wash * 32 + ord(Terrain), frame 2
  SidUnseen = 90                  ## a cell the cog has never seen
  SidCog = 60                     ## + ord(Facing), 4 chips
  SidCogSleep = 64
  SidCreature = 70                ## + ord(CreatureKind), 4 chips

  ## Object id bands. ONE object per cell, then the creatures, then the cog.
  OidCell = 1000
  OidCreature = 60100
  OidAgent = 60000

type
  GlobalViewerState* = object
    initialized*: bool
    spritesSent*: bool
    objectIds*: seq[int]
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    selectedJoinOrder*: int
    clickPending*: bool
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    sentCell*: seq[int]        ## per cell, the sprite id this viewer holds
    sentCreatures*: int

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]

proc initGlobalViewerState*(): GlobalViewerState =
  GlobalViewerState(
    selectedJoinOrder: -1,
    replaySeekTick: -1,
    sentCell: newSeq[int](WorldCells)
  )

# ---------------------------------------------------------------------------
#  Install-time bakes
# ---------------------------------------------------------------------------

proc tileFrom(source: Image, size: int, r, g, b: int): Image =
  ## One cell-sized tile cut from a source texture and tinted, the way the
  ## starter bakes endzone paint.
  result = newImage(size, size)
  let scaled = source.resize(max(size, source.width div 8),
                             max(size, source.height div 8))
  for y in 0 ..< size:
    for x in 0 ..< size:
      let pixel = scaled.unsafe[(x * 7) mod scaled.width,
                                (y * 11) mod scaled.height].rgba()
      let luma = (int(pixel.r) + int(pixel.g) + int(pixel.b)) div 3
      result.unsafe[x, y] = rgba(
        uint8(clamp(r * luma div 160, 0, 255)),
        uint8(clamp(g * luma div 160, 0, 255)),
        uint8(clamp(b * luma div 160, 0, 255)), 255).rgbx()

proc gridlines(image: Image) =
  for i in 0 ..< image.width:
    image.unsafe[i, 0] = rgba(20, 18, 14, 90).rgbx()
    image.unsafe[0, i] = rgba(20, 18, 14, 90).rgbx()

proc bevel(image: Image, light, dark: ColorRGBA) =
  ## Masonry bevel: a lit top-left edge and a shadowed bottom-right one, so a
  ## rock face reads as masonry rather than a grey bar.
  let size = image.width
  for i in 0 ..< size:
    image.unsafe[i, 0] = light.rgbx()
    image.unsafe[0, i] = light.rgbx()
    image.unsafe[i, size - 1] = dark.rgbx()
    image.unsafe[size - 1, i] = dark.rgbx()

proc solid(size: int, colour: ColorRGBA): Image =
  result = newImage(size, size)
  result.fill(colour)

proc fleck(image: Image, colour: ColorRGBA, modulus, offset: int) =
  ## A deterministic procedural speckle — blades on grass, grain on sand.
  let size = image.width
  for y in 0 ..< size:
    for x in 0 ..< size:
      if (x * 5 + y * 3 + offset) mod modulus == 0:
        image.unsafe[x, y] = colour.rgbx()

proc seam(image: Image, colour: ColorRGBA) =
  ## An ore seam baked into the stone tile.
  let size = image.width
  for i in 2 ..< size - 2:
    let y = size div 2 + ((i * 7) mod 5) - 2
    if y >= 0 and y < size:
      image.unsafe[i, y] = colour.rgbx()
      if y + 1 < size: image.unsafe[i, y + 1] = colour.rgbx()

proc canopy(image: Image, trunk, leaf: ColorRGBA) =
  ## A procedural tree canopy over the grass tile.
  let
    size = image.width
    centre = size div 2
    radius = size * 2 div 5
  for y in 0 ..< size:
    for x in 0 ..< size:
      let d2 = (x - centre) * (x - centre) + (y - centre + 2) * (y - centre + 2)
      if d2 <= radius * radius:
        let shade = 220 - (x + y) * 40 div (2 * size)
        image.unsafe[x, y] = rgba(
          uint8(int(leaf.r) * shade div 255),
          uint8(int(leaf.g) * shade div 255),
          uint8(int(leaf.b) * shade div 255), 255).rgbx()
  for y in centre + radius - 2 ..< size:
    for x in centre - 1 .. centre + 1:
      if x >= 0 and y >= 0 and x < size and y < size:
        image.unsafe[x, y] = trunk.rgbx()

proc lavaChip(size, frame: int): Image =
  ## Two frames of orange with a black crust, cycled at 4 Hz.
  result = newImage(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        wave = ((x * 5 + y * 3 + frame * 7) mod 32)
        heat = 150 + wave * 3
      if ((x div 5 + y div 4 + frame) mod 5) == 0:
        result.unsafe[x, y] = rgba(70, 26, 18, 255).rgbx()
      else:
        result.unsafe[x, y] = rgba(uint8(min(255, heat + 60)),
                                   uint8(min(200, heat div 3)), 30, 255).rgbx()

proc waterChip(size, frame: int, bed: Image): Image =
  ## Two frames of the bed tinted blue with an offset ripple, cycled at 2 Hz.
  result = newImage(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let grain = bed.unsafe[x, y].rgba()
      let ripple = if ((x + y * 2 + frame * 3) mod 9) < 2: 40 else: 0
      result.unsafe[x, y] = rgba(
        uint8(min(255, int(grain.r) div 3 + ripple)),
        uint8(min(255, int(grain.g) div 2 + 40 + ripple)),
        uint8(min(255, 120 + int(grain.b) div 2 + ripple)), 255).rgbx()

proc structureChip(size: int, panel: Image, top: ColorRGBA): Image =
  ## A table or a furnace: the wall crop with a baked top.
  result = newImage(size, size)
  let inset = size div 8
  for y in inset ..< size - inset:
    for x in inset ..< size - inset:
      let grain = panel.unsafe[x, y].rgba()
      result.unsafe[x, y] = rgba(grain.r, grain.g, grain.b, 255).rgbx()
  for x in inset ..< size - inset:
    for y in inset .. inset + max(1, size div 6):
      result.unsafe[x, y] = top.rgbx()

proc plantChip(size: int, bed: Image, ripe: bool): Image =
  result = bed.copy()
  let centre = size div 2
  for y in centre - size div 4 ..< size - 2:
    for x in centre - 1 .. centre + 1:
      if x >= 0 and y >= 0 and x < size and y < size:
        result.unsafe[x, y] = rgba(96, 156, 78, 255).rgbx()
  if ripe:
    for y in centre - size div 3 .. centre - size div 6:
      for x in centre - 2 .. centre + 2:
        if x >= 0 and y >= 0 and x < size and y < size:
          result.unsafe[x, y] = rgba(226, 84, 62, 255).rgbx()

proc arrowChip(size: int): Image =
  ## A 3 px procedural dart: a render of an arrow at 24 px is a smudge.
  result = newImage(size, size)
  for i in 2 ..< size - 2:
    result.unsafe[i, size div 2] = rgba(238, 228, 206, 255).rgbx()
    result.unsafe[i, size div 2 - 1] = rgba(120, 110, 96, 255).rgbx()

proc creatureChip(size: int, source: Image, wide: bool): Image =
  ## One nano-banana render, fitted to a cell. A cow is wide and low; a zombie
  ## and a skeleton stand.
  result = newImage(size, size)
  let body =
    if wide: source.resize(size, size * 3 div 4)
    else: source.resize(size * 7 div 8, size)
  result.draw(body, translate(vec2(
    float32((size - body.width) div 2), float32(size - body.height))))

proc cogChip(size: int, dir: Facing, source: Image, sleeping: bool): Image =
  ## The cog at one of its four facings — the nano-banana render for that
  ## facing — with a small procedural heading wedge baked on the leading edge.
  result = newImage(size, size)
  let body = source.resize(size * 7 div 8, size * 7 div 8)
  result.draw(body, translate(vec2(float32(size div 16), float32(size div 16))))
  if sleeping:
    for y in 0 ..< size div 3:
      for x in size * 2 div 3 ..< size:
        if ((x + y) mod 4) == 0:
          result.unsafe[x, y] = rgba(240, 232, 210, 220).rgbx()
    return
  ## The heading wedge: a triangle on the facing edge, so the facing reads
  ## even at the 8 px cells of a 360 px embed.
  let
    half = size div 2
    depth = max(2, size div 8)
  for step in 0 ..< depth:
    let span = half - step * half div max(1, depth)
    for offset in -span .. span:
      var x, y: int
      case dir
      of fRight: (x, y) = (size - 1 - step, half + offset)
      of fLeft: (x, y) = (step, half + offset)
      of fDown: (x, y) = (half + offset, size - 1 - step)
      of fUp: (x, y) = (half + offset, step)
      if x >= 0 and y >= 0 and x < size and y < size:
        result.unsafe[x, y] = rgba(240, 208, 96, 235).rgbx()

proc washed(source: Image, wash: int): Image =
  ## The two-level fog wash and the night wash, BAKED. A cell inside the 9 x 9
  ## window is drawn clean; a cell seen but outside it is drawn under a light
  ## wash with its remembered terrain; at night the whole board deepens toward
  ## blue with a warm lift around the cog (which is what the bright variant
  ## is, at night).
  result = newImage(source.width, source.height)
  let
    dim = wash == WashDayDim or wash == WashNightDim
    night = wash >= WashNight
  for i in 0 ..< source.width * source.height:
    let pixel = source.data[i].rgba()
    var r = int(pixel.r)
    var g = int(pixel.g)
    var b = int(pixel.b)
    if night:
      r = (r * 42 + 14 * 58) div 100
      g = (g * 46 + 22 * 54) div 100
      b = (b * 60 + 96 * 40) div 100
    if dim:
      r = r * 68 div 100
      g = g * 70 div 100
      b = (b * 76 + 34 * 24) div 100
    result.data[i] = rgba(uint8(clamp(r, 0, 255)), uint8(clamp(g, 0, 255)),
                          uint8(clamp(b, 0, 255)), pixel.a).rgbx()

proc rgbaBytes(image: Image): seq[uint8] =
  ## Straight (un-premultiplied) RGBA, which is what the sprite protocol's
  ## client-side compositor expects.
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let pixel = image.data[i].rgba()
    result[i * 4] = pixel.r
    result[i * 4 + 1] = pixel.g
    result[i * 4 + 2] = pixel.b
    result[i * 4 + 3] = pixel.a

var
  bakedSprites: seq[tuple[id: int, pixels: seq[uint8]]]
  bakedReady = false
  chipImages: Table[int, Image]
  chipReady = false

proc bakeSprites() =
  ## ONE static bake per process. Everything the board draws is here.
  if bakedReady:
    return
  bakedReady = true
  let
    floorSource = decodeImage(FloorArt)
    wallSource = decodeImage(WallArtH)
    crateSource = decodeImage(WallArtV)
    cogSources = [decodeImage(CogArt[fUp]), decodeImage(CogArt[fRight]),
                  decodeImage(CogArt[fDown]), decodeImage(CogArt[fLeft])]
  var grass = tileFrom(floorSource, CellPx, 92, 148, 78)
  grass.fleck(rgba(120, 176, 92, 255), 11, 0)
  grass.gridlines()
  var sand = tileFrom(floorSource, CellPx, 208, 184, 118)
  sand.fleck(rgba(228, 208, 150, 255), 13, 3)
  sand.gridlines()
  var stone = tileFrom(wallSource, CellPx, 150, 146, 138)
  stone.bevel(rgba(196, 190, 176, 255), rgba(46, 42, 36, 255))
  var bedrock = tileFrom(wallSource, CellPx, 78, 74, 70)
  bedrock.bevel(rgba(112, 106, 98, 255), rgba(20, 18, 16, 255))
  var path = tileFrom(wallSource, CellPx, 96, 90, 82)
  path.gridlines()
  ## pixie's `Image` is a REF type: `var tree = grass` would alias the grass
  ## tile and paint the canopy onto every grass cell in the world. Every
  ## derived chip is an explicit copy.
  var tree = grass.copy()
  tree.canopy(rgba(96, 68, 40, 255), rgba(58, 128, 62, 255))
  let crate = tileFrom(crateSource, CellPx, 168, 132, 92)

  var terrainChips: array[Terrain, Image]
  terrainChips[tGrass] = grass
  terrainChips[tSand] = sand
  terrainChips[tWater] = waterChip(CellPx, 0, grass)
  terrainChips[tStone] = stone
  terrainChips[tPath] = path
  terrainChips[tTree] = tree
  for (ore, colour) in [(tCoal, rgba(24, 22, 20, 255)),
                        (tIron, rgba(190, 120, 70, 255)),
                        (tDiamond, rgba(120, 226, 236, 255))]:
    var chip = stone.copy()
    chip.seam(colour)
    terrainChips[ore] = chip
  terrainChips[tLava] = lavaChip(CellPx, 0)
  terrainChips[tBedrock] = bedrock
  terrainChips[tTable] = structureChip(CellPx, crate, rgba(176, 132, 84, 255))
  terrainChips[tFurnace] = structureChip(CellPx, stone, rgba(226, 110, 46, 255))
  terrainChips[tSapling] = plantChip(CellPx, grass, false)
  terrainChips[tRipePlant] = plantChip(CellPx, grass, true)

  var altChips: array[Terrain, Image]
  altChips[tWater] = waterChip(CellPx, 4, grass)
  altChips[tLava] = lavaChip(CellPx, 3)

  ## Four baked variants per terrain — day / day-remembered / night /
  ## night-remembered — so fog and the night wash cost NO extra objects.
  for wash in 0 ..< WashCount:
    for terrain in Terrain:
      bakedSprites.add((SidTerrain + wash * 32 + ord(terrain),
        washed(terrainChips[terrain], wash).rgbaBytes()))
      if terrain in {tWater, tLava}:
        bakedSprites.add((SidTerrainAlt + wash * 32 + ord(terrain),
          washed(altChips[terrain], wash).rgbaBytes()))
  bakedSprites.add((SidUnseen, solid(CellPx, rgba(4, 4, 6, 255)).rgbaBytes()))
  for d, dir in Facings:
    bakedSprites.add((SidCog + ord(dir),
                      cogChip(CellPx, dir, cogSources[d], false).rgbaBytes()))
  bakedSprites.add((SidCogSleep,
    cogChip(CellPx, fDown, cogSources[2], true).rgbaBytes()))
  for kind in ckCow .. ckSkeleton:
    bakedSprites.add((SidCreature + ord(kind),
      creatureChip(CellPx, decodeImage(CreatureArt[kind]),
                   kind == ckCow).rgbaBytes()))
  bakedSprites.add((SidCreature + ord(ckArrow), arrowChip(CellPx).rgbaBytes()))

proc bakeChipImages() =
  ## The same chips as `Image`s, for the offline board preview.
  if chipReady:
    return
  chipReady = true
  bakeSprites()
  for sprite in bakedSprites:
    var image = newImage(CellPx, CellPx)
    for i in 0 ..< CellPx * CellPx:
      image.data[i] = rgba(sprite.pixels[i * 4], sprite.pixels[i * 4 + 1],
                           sprite.pixels[i * 4 + 2],
                           sprite.pixels[i * 4 + 3]).rgbx()
    chipImages[sprite.id] = image

proc spriteFor(terrain: Terrain, wash, tick: int): int =
  ## The sprite a cell draws as, at one wash level. Water shimmers at 2 Hz and
  ## lava crusts at 4 Hz; every other terrain is one static chip.
  let base = wash * 32 + ord(terrain)
  case terrain
  of tWater:
    if (tick div 12) mod 2 == 0: SidTerrain + base else: SidTerrainAlt + base
  of tLava:
    if (tick div 6) mod 2 == 0: SidTerrain + base else: SidTerrainAlt + base
  else:
    SidTerrain + base

# ---------------------------------------------------------------------------
#  Viewer input
# ---------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands are intercepted BEFORE the legacy char-by-char transport path,
  ## so a multi-digit tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = (if item.hasLayer: item.layer else: MapLayerId)
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        discard          ## one seat: there is nothing to select
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientInputMessage:
      discard
    of SpriteClientReadyMessage, SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(state: var PlayerViewerState, message: string,
                               inputMask: var uint8, pressedMask: var uint8,
                               chatText: var string) =
  ## The seat's own socket. Its Sprite v1 chat message is where the
  ## REGISTRATION blob arrives; `server.nim` intercepts it.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage:
      pressedMask = pressedMask or (item.mask and not inputMask)
      inputMask = item.mask
    else:
      discard

# ---------------------------------------------------------------------------
#  The packet
# ---------------------------------------------------------------------------

proc renderBoardImage*(sim: SimServer): Image =
  ## The board as one image, from the SAME baked chips the sprite packet
  ## places. `tools/dump_board_preview.nim` writes it to a PNG so the
  ## install-time art is reviewable without a browser.
  bakeSprites()
  bakeChipImages()
  result = newImage(BoardPx, BoardPx)
  result.fill(rgba(8, 8, 10, 255))
  if not sim.started:
    return
  let origin = viewOrigin(sim.cog.x, sim.cog.y)
  let night = not sim.isDaylight()
  for y in 0 ..< WorldSize:
    for x in 0 ..< WorldSize:
      let at = translate(vec2(float32(x * CellPx), float32(y * CellPx)))
      let slot = idx(x, y)
      if not sim.knownMap.cells[slot].seen:
        result.draw(chipImages[SidUnseen], at)
        continue
      let live = x >= origin.x and x < origin.x + ViewSize and
                 y >= origin.y and y < origin.y + ViewSize
      let wash =
        if night: (if live: WashNight else: WashNightDim)
        else: (if live: WashDay else: WashDayDim)
      result.draw(chipImages[spriteFor(sim.world.cells[slot], wash,
                                       sim.tickCount)], at)
  for creature in sim.herd.list:
    if creature.alive:
      result.draw(chipImages[SidCreature + ord(creature.kind)],
        translate(vec2(float32(creature.x * CellPx),
                       float32(creature.y * CellPx))))
  result.draw(
    chipImages[if sim.cog.asleep: SidCogSleep
               else: SidCog + ord(sim.cog.facing)],
    translate(vec2(float32(sim.cog.x * CellPx), float32(sim.cog.y * CellPx))))

proc addChrome*(packet: var seq[uint8], json: string) =
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], json)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1,
  replayLooping = false,
  replayEnabled = false,
  replayMismatchTick = -1
): seq[uint8] =
  ## Builds the board updates for one viewer. The protocol is RETAINED-MODE —
  ## a client keeps a placement until it is replaced — so an unchanged cell
  ## costs no bytes, which is what makes a 4096-cell board affordable.
  bakeSprites()
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  nextState.clickPending = false
  if nextState.sentCell.len != WorldCells:
    nextState.sentCell = newSeq[int](WorldCells)

  if not nextState.initialized:
    nextState.initialized = true
    result.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
    result.addViewport(MapLayerId, BoardPx, BoardPx)
  if not nextState.spritesSent:
    nextState.spritesSent = true
    for sprite in bakedSprites:
      result.addSprite(sprite.id, CellPx, CellPx, sprite.pixels)

  if not sim.started:
    return

  ## 2. The board, ONE object per cell in ascending (y, x), emitted
  ##    INCREMENTALLY: an unchanged cell costs no bytes, and the wash level
  ##    (fog + night) is folded into the sprite so the whole board is 4096
  ##    objects rather than three stacked layers of 4096.
  let origin = viewOrigin(sim.cog.x, sim.cog.y)
  let night = not sim.isDaylight()
  for slot in 0 ..< WorldCells:
    let
      x = slot mod WorldSize
      y = slot div WorldSize
      live = x >= origin.x and x < origin.x + ViewSize and
             y >= origin.y and y < origin.y + ViewSize
    let sprite =
      if not sim.knownMap.cells[slot].seen:
        SidUnseen
      else:
        let wash =
          if night: (if live: WashNight else: WashNightDim)
          else: (if live: WashDay else: WashDayDim)
        spriteFor(sim.world.cells[slot], wash, sim.tickCount)
    if nextState.sentCell[slot] == sprite:
      continue
    nextState.sentCell[slot] = sprite
    result.addObject(OidCell + slot, x * CellPx, y * CellPx, -100, MapLayerId,
      sprite)

  ## 5. Creatures, in the stable creature order, then the cog above them.
  var drawn = 0
  for creature in sim.herd.list:
    if not creature.alive:
      continue
    result.addObject(OidCreature + drawn, creature.x * CellPx,
      creature.y * CellPx, 400 + creature.y * 4, MapLayerId,
      SidCreature + ord(creature.kind))
    inc drawn
  for i in drawn ..< nextState.sentCreatures:
    result.addDeleteObject(OidCreature + i)
  nextState.sentCreatures = drawn

  result.addObject(OidAgent, sim.cog.x * CellPx, sim.cog.y * CellPx,
    500 + sim.cog.y * 4, MapLayerId,
    if sim.cog.asleep: SidCogSleep else: SidCog + ord(sim.cog.facing))

  ## The chrome sprite is added by the CALLER (the live server and
  ## `buildReplayViewerPacket`), exactly as the starter does it, so the board
  ## packet and the HUD frame stay separable.
