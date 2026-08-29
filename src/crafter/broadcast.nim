## `stepEvents` (the derived broadcast events), `buildStateJson` (the chrome
## frame) and `rosterJson`. Forked from `coworld-ctf/src/ctf/broadcast.nim`:
## the STRUCTURE is the starter's — the same frame keys, the same
## once-per-viewer lead/beat/lull shipping — with the fields retargeted.
##
## Derived events cost NO replay bytes and are identical live and in replay,
## because both sides derive them from the same sim.

import std/[json, strutils]
import sim

type
  BroadcastTracker* = object
    ## The starter's tracker diffs state to derive events. This game's sim
    ## already emits its own event list per tick (`sim.pending`), so the
    ## tracker only carries the resync hook the shared playback path calls.
    lastTick*: int

proc initBroadcastTracker*(): BroadcastTracker =
  BroadcastTracker(lastTick: -1)

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  tracker.lastTick = sim.tickCount

proc eventJson*(sim: SimServer, event: SimEvent): JsonNode =
  ## One derived event, in the documented shape for its kind.
  result = %*{"k": $event.kind, "t": event.tick}
  case event.kind
  of evTurn:
    result["n"] = %event.i
    result["tick"] = %event.n
  of evPlan:
    result["n"] = %event.i
    result["verbs"] = %event.a
    result["truncated"] = %(event.n != 0)
    result["dropped"] = %event.m
    result["interrupted"] = %event.b
  of evSay:
    result["text"] = %event.a
  of evFallback:
    result["cause"] = %event.a
  of evAchievement:
    result["id"] = %event.a
    result["index"] = %event.i
    result["n"] = %event.n
    result["of"] = %event.m
  of evCollect:
    result["what"] = %event.a
    result["x"] = %event.x
    result["y"] = %event.y
    result["count"] = %event.n
  of evCraft:
    result["what"] = %event.a
  of evPlace:
    result["what"] = %event.a
    result["x"] = %event.x
    result["y"] = %event.y
  of evEat:
    result["what"] = %event.a
    result["food"] = %event.n
  of evDrink:
    result["drink"] = %event.n
  of evHurt:
    result["by"] = %event.a
    result["amount"] = %event.n
    result["hp"] = %event.m
    result["x"] = %event.x
    result["y"] = %event.y
  of evHeal:
    result["hp"] = %event.n
  of evKill:
    result["what"] = %event.a
    result["x"] = %event.x
    result["y"] = %event.y
  of evSpawn:
    result["what"] = %event.a
    result["x"] = %event.x
    result["y"] = %event.y
  of evBurn:
    result["n"] = %event.n
  of evSleep:
    result["state"] = %event.a
    result["energy"] = %event.n
  of evNightfall, evDaybreak:
    result["day"] = %event.i
  of evStarve:
    result["which"] = %event.a
    result["hp"] = %event.n
  of evDeath:
    result["by"] = %event.a
    result["tick"] = %event.n
  of evBudget:
    result["turn"] = %event.i
    result["remaining_s"] = %event.n
  of evEnd:
    result["reason"] = %event.a
    result["endRule"] = %event.b
    result["unlocked"] = %event.i
    result["of"] = %event.n
    result["score"] = %event.m

proc stepEvents*(sim: var SimServer, tracker: var BroadcastTracker,
                 events: JsonNode) =
  ## Drains this tick's derived events into `events`. Both the live server and
  ## replay playback call it once per tick, from the same sim state, so the
  ## feed tells the identical story live and in replay.
  tracker.lastTick = sim.tickCount
  if events.isNil:
    sim.pending.setLen(0)
    return
  for event in sim.pending:
    events.add(sim.eventJson(event))
  sim.pending.setLen(0)

proc isBeat*(kind: EventKind): bool =
  ## The scrubber's beat kinds, and the ONLY kinds the appended game block
  ## draws a marker for: exactly the idea's watchability asks (the achievement
  ## checklist lighting up, night-survival tension) plus the two the transport
  ## always needs.
  kind in {evAchievement, evNightfall, evDaybreak, evKill, evDeath,
           evFallback, evEnd}

proc rosterJson*(sim: SimServer): JsonNode =
  ## Spectator-side only: this is where the seat's REAL policy name lives. It
  ## never reaches an observation or a prompt.
  result = newJArray()
  for slot in 0 ..< sim.seatCount():
    var name = "Baseline (" & $(slot + 1) & ")"
    var policy = ""
    var kind = "scripted"
    for entry in sim.players:
      if entry.slot != slot:
        continue
      if entry.name.len > 0: name = entry.name
      policy = entry.policy
      if entry.kind.len > 0: kind = entry.kind
    result.add(%*{
      "s": slot,
      "name": name,
      "alias": seatAlias(slot),
      "team": "red",
      "policy": (if policy.len > 0: policy else: name),
      "kind": kind,
      "alive": sim.cog.health() > 0,
      "lives": sim.cog.health(),
      "carry": sim.achievementsUnlocked()
    })

proc teamStateJson(sim: SimServer): JsonNode =
  ## The single seat's plate state. The key is `red` because there is one cog
  ## and it is red, which is what keeps the starter's plate colour, its
  ## left/right column layout and its CSS utility classes working unchanged.
  ## `lives` carries the ACHIEVEMENT COUNT (0..22) — the series the
  ## achievement sparkline plots.
  %*{
    "lives": sim.achievementsUnlocked(),
    "prog": sim.achievementsUnlocked(),
    "held": sim.achievementsUnlocked(),
    "cov": sim.score(),
    "own": false,
    "tags": sim.knownMap.cellsSeen(),
    "cogs": 1,
    "flag": "home",
    "carrier": -1
  }

proc runStateJson(sim: SimServer): JsonNode =
  ## Everything the appended CRAFTER block draws: the achievement checklist,
  ## the vitals bars, the inventory strip, the tool chips, the agent-view
  ## inset, the follow-cam target and the endcard rows.
  var chips = newJArray()
  for a in Achievement:
    chips.add(%*{"id": $a, "i": ord(a), "on": sim.ledger.unlocked[a],
                 "t": sim.ledger.tick[a]})
  var view = newJArray()
  if sim.started:
    for row in sim.viewRows():
      view.add(%row)
  var inventory = newJObject()
  for resource in Resource:
    inventory[$resource] = %sim.cog.inventory[resource]
  var tools = newJObject()
  for tool in Tool:
    tools[$tool] = %sim.cog.tools[tool]
  %*{
    "count": sim.achievementsUnlocked(),
    "of": AchievementCount,
    "par": sim.config.parAchievements,
    "score": sim.score(),
    "chips": chips,
    "health": sim.cog.health(),
    "food": sim.cog.food(),
    "drink": sim.cog.drink(),
    "energy": sim.cog.energy(),
    "vitalMax": VitalMax,
    "inv": inventory,
    "tools": tools,
    "x": sim.cog.x,
    "y": sim.cog.y,
    "cell": BoardCellPx,
    "camera": CameraCells,
    "world": WorldSize,
    "facing": $sim.cog.facing,
    "asleep": sim.cog.asleep,
    "day": sim.dayOf(),
    "night": not sim.isDaylight(),
    "turn": sim.turnsPlayed,
    "turns": sim.config.maxTurns,
    "tick": sim.survivalTicks(),
    "ticks": sim.config.maxTicks,
    "seen": sim.knownMap.cellsSeen(),
    "cells": WorldCells,
    "mined": sim.blocksMined,
    "placed": sim.blocksPlaced,
    "crafted": sim.itemsCrafted,
    "cows": sim.cowsEaten,
    "interrupts": sim.interrupts,
    "fallbacks": sim.fallbackTurns,
    "deathCause": $sim.deathCause,
    "view": view
  }

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: float,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## The broadcast chrome frame. Board-derived STATE is always present, so
  ## even a frame reached by a seek hydrates the scorebug and the endcard with
  ## no events at all.
  var teams = newJObject()
  teams["red"] = sim.teamStateJson()

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": povSlot,
    "regime": sim.config.variant,
    "game": 1,
    "games": 1,
    "turnTicks": sim.config.turnTicks,
    "teams": teams,
    "roster": sim.rosterJson(),
    "cf": sim.runStateJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

  ## The commander lines. This is where a spectator SEES the LLM playing: the
  ## `say` each turn carried, live and in replay from one source.
  if sim.feedDirectives.len > 0:
    var records = newJArray()
    for record in sim.feedDirectives:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["directives"] = records

  if leadSeries.len > 0:
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": ["red"], "pts": pts}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  ## The endcard is STATE, not an event: present on every game-over frame so a
  ## viewer who seeks straight to the end still sees the verdict.
  if sim.phase == GameOver:
    var overTeams = newJObject()
    overTeams["red"] = %*{"lives": sim.achievementsUnlocked(),
                          "prog": sim.achievementsUnlocked()}
    state["over"] = %*{
      "winner": (if sim.achievementsUnlocked() >= sim.config.parAchievements:
                   "red" else: ""),
      "draw": false,
      "timeLimit": sim.endRule in {edTurnCap, edTickCap},
      "teams": overTeams,
      "endRule": $sim.endRule,
      "reason": $sim.endReason,
      "game": 1,
      "games": 1,
      "regime": sim.config.variant,
      "unlocked": sim.achievementsUnlocked(),
      "of": AchievementCount,
      "par": sim.config.parAchievements,
      "deathCause": $sim.deathCause,
      "day": sim.dayOf(),
      "score": sim.score()
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state
