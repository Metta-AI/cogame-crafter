## Renders one baked board to a PNG so the install-time art can be eyeballed
## without a browser. The board the viewer composites is the SAME set of baked
## chips this tool blits, so a black board here is a black board there.
##
##   nim c -r --path:src tools/dump_board_preview.nim /tmp/board.png [seed] [turns]

import std/[os, strutils]
import pixie
import crafter/[sim, driver, directives, baselines]
import crafter/global as board

when isMainModule:
  let
    outPath = if paramCount() >= 1: paramStr(1) else: "board.png"
    seed = if paramCount() >= 2: parseInt(paramStr(2)) else: 42
    turns = if paramCount() >= 3: parseInt(paramStr(3)) else: 12
  var config = defaultGameConfig()
  config.seed = seed
  var game = initSimServer(config)
  game.phase = Playing
  game.gameStartTick = game.tickCount
  game.startRun()
  for i in 0 ..< turns:
    if not game.beginTurn(): break
    let plan = foragerPlan(game)
    let expansion = expandPlan(game.knownMap, game.cog.x, game.cog.y,
      plan.actions, config.macroPrimitiveCap, config.turnTicks)
    game.installPlan(expansion.primitives, expansion.truncated,
      plan.dropped + plan.overCap, expansion.unreachable)
    while game.turnActive and game.phase == Playing:
      game.stepTick()
      game.pending.setLen(0)
  let image = board.renderBoardImage(game)
  image.writeFile(outPath)
  echo "wrote ", outPath, " (", image.width, "x", image.height, ") tick ",
    game.tickCount, " unlocked ", game.achievementsUnlocked()
