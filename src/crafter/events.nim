## The tier-2 analysis stream written to `COGAME_EVENTS_URI`: the starter's
## JSON-lines `eventsJsonl` with `SimEventKind` reduced to this game's set and
## the mandatory trailing summary row kept.
##
## `Primitive` is the per-tick row that makes this stream a full action trace
## for `cogamer-rl` — 1344 rows an episode, which is what the idea's
## LLM-vs-RL ladder needs and what the replay deliberately does not carry.

import std/[json, strutils]
import sim

type
  SimEventKind* = enum
    TurnStart = "TurnStart"
    Directive = "Directive"
    Fallback = "Fallback"
    PrimitiveStep = "Primitive"
    Collect = "Collect"
    Craft = "Craft"
    Place = "Place"
    Eat = "Eat"
    Drink = "Drink"
    Hurt = "Hurt"
    Heal = "Heal"
    Kill = "Kill"
    Spawn = "Spawn"
    Burn = "Burn"
    Sleep = "Sleep"
    Nightfall = "Nightfall"
    Daybreak = "Daybreak"
    Starve = "Starve"
    AchievementRow = "Achievement"
    Death = "Death"

proc analysisKind*(kind: EventKind): tuple[ok: bool, kind: SimEventKind] =
  case kind
  of evTurn: (true, TurnStart)
  of evPlan: (true, Directive)
  of evFallback: (true, Fallback)
  of evCollect: (true, Collect)
  of evCraft: (true, Craft)
  of evPlace: (true, Place)
  of evEat: (true, Eat)
  of evDrink: (true, Drink)
  of evHurt: (true, Hurt)
  of evHeal: (true, Heal)
  of evKill: (true, Kill)
  of evSpawn: (true, Spawn)
  of evBurn: (true, Burn)
  of evSleep: (true, Sleep)
  of evNightfall: (true, Nightfall)
  of evDaybreak: (true, Daybreak)
  of evStarve: (true, Starve)
  of evAchievement: (true, AchievementRow)
  of evDeath: (true, Death)
  else: (false, TurnStart)

proc primitiveRow*(sim: SimServer, primitive: Primitive): string =
  ## The per-tick action trace row.
  $(%*{
    "type": $PrimitiveStep,
    "tick": sim.tickCount,
    "do": $primitive,
    "x": sim.cog.x,
    "y": sim.cog.y,
    "facing": $sim.cog.facing,
    "health": sim.cog.health(),
    "food": sim.cog.food(),
    "drink": sim.cog.drink(),
    "energy": sim.cog.energy(),
    "unlocked": sim.achievementsUnlocked()
  })

proc eventRow*(sim: SimServer, event: SimEvent): string =
  let mapped = analysisKind(event.kind)
  if not mapped.ok:
    return ""
  var node = %*{
    "type": $mapped.kind,
    "tick": event.tick,
    "i": event.i,
    "x": event.x,
    "y": event.y,
    "n": event.n,
    "m": event.m
  }
  if event.a.len > 0: node["a"] = %event.a
  if event.b.len > 0: node["b"] = %event.b
  if event.c.len > 0: node["c"] = %event.c
  $node

proc summaryRow*(sim: SimServer, events: int): string =
  ## The MANDATORY trailing summary row.
  $(%*{
    "type": "summary",
    "ticks": sim.tickCount,
    "events": events,
    "gameVersion": GameVersion
  })

proc eventsJsonl*(rows: seq[string]): string =
  rows.join("\n") & "\n"
