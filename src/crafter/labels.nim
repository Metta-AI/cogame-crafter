## The board-label vocabulary contract. `tests/label_manifest.txt` pins the
## exact set of strings this game may draw on the board, and test 41 in
## `tests/test_crafter_viewer.nim` re-generates it and diffs it against the
## committed file — a label change and its manifest update land in the same
## commit.
##
## Scoped, like the starter's, to the POLICY contract: the words a cog can see
## or that name a cog. Spectator chrome strings live in the viewer and are
## covered by `tests/test_crafter_endcard_labels.nim` instead.

import std/[algorithm, sequtils, strutils]
import sim

proc boardLabels*(): seq[string] =
  ## Every string the board may draw, in sorted order.
  for terrain in Terrain:
    result.add($terrain)
  for kind in CreatureKind:
    result.add($kind)
  for primitive in Primitive:
    result.add($primitive)
  for achievement in Achievement:
    result.add($achievement)
  for resource in Resource:
    result.add($resource)
  for tool in Tool:
    result.add($tool)
  for vital in Vital:
    result.add($vital)
  for facing in Facings:
    result.add(toUpperAscii($facing))
  result.add(seatAlias(0))
  result.sort()
  result = deduplicate(result)

proc labelManifest*(): string =
  boardLabels().join("\n") & "\n"
