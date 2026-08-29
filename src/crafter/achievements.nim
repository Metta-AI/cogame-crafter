## The twenty-two achievements: the ids in canonical order, the predicate
## bridge, the `achievementTick[22]` array this fork adds, and the ledger.
##
## Each unlocks ONCE, permanently, the tick its predicate first becomes true,
## and is never revoked — the starter's `recordAchievement` discipline
## (`src/ctf/roster.nim:640-648`) kept verbatim in shape, with ctf's fifteen
## paintball ids replaced by these twenty-two.

import sim_types

type
  Ledger* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    unlocked*: array[Achievement, bool]
    tick*: array[Achievement, int]
    count*: int

proc initLedger*(): Ledger =
  for a in Achievement:
    result.tick[a] = -1

proc recordAchievement*(ledger: var Ledger, a: Achievement, tick: int): bool =
  ## Deduplicates, exactly as the starter's does. Returns true only the first
  ## time, which is what emits the `achievement` event.
  if ledger.unlocked[a]:
    return false
  ledger.unlocked[a] = true
  ledger.tick[a] = tick
  inc ledger.count
  true

proc has*(ledger: Ledger, a: Achievement): bool = ledger.unlocked[a]

proc allUnlocked*(ledger: Ledger): bool = ledger.count >= AchievementCount

proc achievementIds*(): seq[string] =
  for a in Achievement:
    result.add($a)

proc collectAchievement*(resource: Resource): tuple[ok: bool, a: Achievement] =
  case resource
  of rWood: (true, aCollectWood)
  of rStone: (true, aCollectStone)
  of rCoal: (true, aCollectCoal)
  of rIron: (true, aCollectIron)
  of rDiamond: (true, aCollectDiamond)
  of rSapling: (true, aCollectSapling)

proc placeAchievement*(terrain: Terrain): tuple[ok: bool, a: Achievement] =
  case terrain
  of tStone: (true, aPlaceStone)
  of tTable: (true, aPlaceTable)
  of tFurnace: (true, aPlaceFurnace)
  of tSapling: (true, aPlacePlant)
  else: (false, aCollectWood)

proc craftAchievement*(tool: Tool): Achievement =
  case tool
  of toWoodPickaxe: aMakeWoodPickaxe
  of toStonePickaxe: aMakeStonePickaxe
  of toIronPickaxe: aMakeIronPickaxe
  of toWoodSword: aMakeWoodSword
  of toStoneSword: aMakeStoneSword
  of toIronSword: aMakeIronSword

proc killAchievement*(kind: CreatureKind): tuple[ok: bool, a: Achievement] =
  case kind
  of ckCow: (true, aEatCow)
  of ckZombie: (true, aDefeatZombie)
  of ckSkeleton: (true, aDefeatSkeleton)
  of ckArrow: (false, aEatCow)
