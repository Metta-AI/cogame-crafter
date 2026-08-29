## The crafter game server entrypoint.
##
## SEED RANDOMISATION HAPPENS INSIDE `runServerLoop`, before any seed-derived
## draw and before the resolved config is written into the replay header, so
## every generated layout follows the FINAL seed (the starter's rule).

import crafter/server

when isMainModule:
  runServerLoop()
