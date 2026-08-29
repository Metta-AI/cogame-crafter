## The simulation: the step loop of §The game exactly as numbered, `gameHash`,
## end evaluation, scoring, and the seat's observation builder.
##
## THE WHOLE PHYSICS OF THE GAME IS `stepTick` AND NOTHING ELSE MUTATES THE
## WORLD. All arithmetic is integer only — cell coordinates, the noise
## lattice, vitals, tick counters, BFS distances, achievement ticks, scores.
## There is no floating point anywhere in this module, which is what makes the
## native <-> wasm hash chain exact by construction (and
## `tests/test_crafter_sim.nim` greps for it).

import std/[json, strutils, algorithm]
import sim_types, sim_config, world, agent, creatures, achievements

type
  EventKind* = enum
    ## The closed enum of derived broadcast events.
    ## `tests/test_crafter_events.nim` asserts the emitted set equals exactly
    ## this list.
    evTurn = "turn"
    evPlan = "plan"
    evSay = "say"
    evFallback = "fallback"
    evAchievement = "achievement"
    evCollect = "collect"
    evCraft = "craft"
    evPlace = "place"
    evEat = "eat"
    evDrink = "drink"
    evHurt = "hurt"
    evHeal = "heal"
    evKill = "kill"
    evSpawn = "spawn"
    evBurn = "burn"
    evSleep = "sleep"
    evNightfall = "nightfall"
    evDaybreak = "daybreak"
    evStarve = "starve"
    evDeath = "death"
    evBudget = "budget"
    evEnd = "end"

  SimEvent* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    kind*: EventKind
    tick*: int
    i*, x*, y*, n*, m*: int
    a*, b*, c*: string

  RosterEntry* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    name*: string
    slot*: int
    token*: string
    joinOrder*: int
    address*: string
    connected*: bool
    alias*: string
    policy*: string
    kind*: string
    baseline*: string
    registered*: bool

  SimServer* = object
    ## FLATTY WIRE TYPE — field order is sacred. Keyframes flatty this whole
    ## object, so a reordered field silently re-interprets every recorded
    ## keyframe of every existing replay.
    config*: GameConfig
    phase*: Phase
    tickCount*: int
    gameStartTick*: int
    lobbyTicks*: int
    gameOverTick*: int
    hash*: uint64
    terrainHash*: uint64
    players*: seq[RosterEntry]

    world*: World
    knownMap*: KnownMap
    cog*: Cog
    herd*: Herd
    ledger*: Ledger
    started*: bool
    lastPhaseWasDay*: bool
    ripening*: seq[int]
      ## the cells carrying a sapling ripen timer, so tick step 5 is O(few)
      ## rather than O(4096).

    queue*: seq[Primitive]
    executed*: seq[Primitive]
    turnTick*: int
    turnActive*: bool
    turnsPlayed*: int
    planTruncated*: bool
    lastDropped*: int
    lastUnreachable*: int
    lastInterrupted*: string
    notes*: string

    cellsSeenCount*: int
    damageTaken*: int
    damageDealt*: int
    zombiesKilled*: int
    skeletonsKilled*: int
    cowsEaten*: int
    blocksMined*: int
    blocksPlaced*: int
    itemsCrafted*: int
    ticksAsleep*: int
    interrupts*: int
    daysSurvived*: int
    nightsSurvived*: int
    primitivesExecuted*: int
    actionsDropped*: int
    macrosUnreachable*: int
    repliesRepaired*: int
    llmTurns*: int
    fallbackTurns*: int
    deadSeats*: seq[bool]
    policyKinds*: seq[string]

    deathCause*: DeathCause
    endReason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    pending*: seq[SimEvent]
    feedDirectives*: seq[string]
    gameEventLoggingEnabled*: bool

  SimError* = object of CatchableError

const
  IdentityNames* = ["alpha", "bravo", "charlie", "delta"]
    ## Inherited from the starter's roster: the in-game aliases. With one seat
    ## only `Alpha` is ever used, and it is the ONLY name that appears in an
    ## observation, in a prompt, in a `say`, or on the board.

proc seatAlias*(slot: int): string =
  ## The anonymous cog alias, title-cased. The seat's REAL policy name lives
  ## only in `results.names`, in the replay's join record, and spectator-side
  ## in the viewer.
  let base = IdentityNames[clamp(slot, 0, IdentityNames.high)]
  base[0].toUpperAscii() & base[1 .. ^1]

proc seatCount*(sim: SimServer): int = max(1, sim.config.numAgents)

proc emit(sim: var SimServer, event: SimEvent) =
  var copy = event
  copy.tick = sim.tickCount
  sim.pending.add(copy)

proc runTick*(sim: SimServer): int =
  ## The RUN-RELATIVE tick: 0 on the first tick of play. Every game rule that
  ## reads a clock — the vitals schedule, the day/night phase, the spawn
  ## draws, the sapling draw, the ripen timers and the creature periods —
  ## reads THIS, never `tickCount`. The lobby's length is wall-clock (it is a
  ## wait for a container to dial in), so a rule keyed on the absolute tick
  ## would make an episode of seed `s` depend on how fast the player pod
  ## started, and the note's "the world of seed s is the same world" would be
  ## false.
  max(0, sim.tickCount - sim.gameStartTick)

proc isDaylight*(sim: SimServer): bool =
  isDay(sim.runTick(), sim.config.dayLength, sim.config.dayFraction)

proc dayOf*(sim: SimServer): int =
  dayNumber(sim.runTick(), sim.config.dayLength)

proc ticksToPhaseChange*(sim: SimServer): int =
  let inCycle = sim.runTick() mod max(1, sim.config.dayLength)
  if inCycle < sim.config.dayFraction: sim.config.dayFraction - inCycle
  else: sim.config.dayLength - inCycle

proc achievementsUnlocked*(sim: SimServer): int = sim.ledger.count

proc survivalTicks*(sim: SimServer): int =
  ## Frozen at the tick the episode settled: the shutdown grace keeps stepping
  ## the clock so `/healthz` and `/global` keep answering, and those ticks are
  ## not survival.
  if sim.phase == GameOver: max(0, sim.gameOverTick - sim.gameStartTick)
  else: sim.runTick()

proc score*(sim: SimServer): int =
  ## scores[0] = 10_000 * achievementsUnlocked + survivalTicks. Higher is
  ## better and every term only ever ADDS; the ordering is strictly
  ## lexicographic because maxTicks 1344 < 10_000.
  10_000 * sim.achievementsUnlocked() + sim.survivalTicks()

# ---------------------------------------------------------------------------
#  Terrain mutation, through ONE door so the incremental digest cannot drift
# ---------------------------------------------------------------------------

proc setTerrain(sim: var SimServer, x, y: int, terrain: Terrain) =
  if not inBounds(x, y):
    return
  let old = sim.world.cells[idx(x, y)]
  if old == terrain:
    return
  sim.world.cells[idx(x, y)] = terrain
  sim.terrainHash = mixTerrain(sim.terrainHash, x, y, old, terrain)

# ---------------------------------------------------------------------------
#  gameHash
# ---------------------------------------------------------------------------

proc mixHash(hash: var uint64, value: int) =
  hash = hash xor cast[uint64](int64(value))
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)

proc recomputeHash(sim: var SimServer) =
  ## The fixed mixing order of §Determinism point 4. One divergent bit is
  ## caught at the tick it happens by `checkReplayHash`.
  var hash = 0xCBF29CE484222325'u64
  hash.mixHash(sim.tickCount)
  hash.mixHash(sim.cog.x)
  hash.mixHash(sim.cog.y)
  hash.mixHash(ord(sim.cog.facing))
  hash.mixHash(if sim.cog.asleep: 1 else: 0)
  for vital in Vital:
    hash.mixHash(sim.cog.vitals[vital])
  for resource in Resource:
    hash.mixHash(sim.cog.inventory[resource])
  for tool in Tool:
    hash.mixHash(if sim.cog.tools[tool]: 1 else: 0)
  var mask = 0
  for a in Achievement:
    if sim.ledger.unlocked[a]: mask = mask or (1 shl ord(a))
  hash.mixHash(mask)
  for creature in sim.herd.list:
    if not creature.alive:
      continue
    hash.mixHash(ord(creature.kind))
    hash.mixHash(creature.x)
    hash.mixHash(creature.y)
    hash.mixHash(creature.hp)
    hash.mixHash(creature.lastAct)
  hash = hash xor sim.terrainHash
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)
  hash.mixHash(ord(sim.phase))
  sim.hash = hash

proc gameHash*(sim: SimServer): uint64 = sim.hash

# ---------------------------------------------------------------------------
#  Lifecycle
# ---------------------------------------------------------------------------

proc startRun*(sim: var SimServer) =
  ## Generates the world from `(seed, mountainThreshold)`, places the cog at
  ## (32, 32) facing down, and seeds the incremental terrain digest by folding
  ## the whole grid once.
  sim.world = generate(sim.config.seed, sim.config.mountainThreshold)
  sim.terrainHash = sim.world.terrainDigest()
  sim.cog = newCog(SpawnX, SpawnY)
  sim.herd = Herd()
  sim.ledger = initLedger()
  sim.knownMap = KnownMap()
  sim.started = true
  sim.lastPhaseWasDay = sim.isDaylight()
  sim.deathCause = dcNone
  sim.ripening = @[]
  sim.cellsSeenCount = sim.knownMap.mergeVisible(sim.world, sim.cog.x,
    sim.cog.y, sim.tickCount)

proc finish*(sim: var SimServer, reason: EndReason, rule: EndRule) =
  if sim.phase == GameOver:
    return
  sim.phase = GameOver
  sim.endReason = reason
  sim.endRule = rule
  sim.gameOverTick = sim.tickCount
  sim.emit(SimEvent(kind: evEnd, i: sim.achievementsUnlocked(),
    n: AchievementCount, m: sim.score(), a: $reason, b: $rule))

proc applyStop*(sim: var SimServer, rule: EndRule, detail: string) =
  ## THE LOAD-BEARING STOP. A wall-clock (or fault) fact cannot be re-derived
  ## from sim state, so it is written as ONE record applied by THIS proc on
  ## record and on playback — which is what keeps a deadline-ended replay's
  ## hash chain clean at the stop tick (the particle-worlds scar).
  sim.stopDetail = detail.truncateRunes(MaxStopDetailRunes)
  case rule
  of edWallClock: sim.finish(erDeadline, edWallClock)
  of edFault: sim.finish(erFault, edFault)
  else: sim.finish(erComplete, rule)

proc waitingForPlan*(sim: SimServer): bool =
  ## A TURN IS `turnTicks` TICKS, not "until the queue empties": a plan that
  ## expands to three primitives still costs its whole turn, and the twenty-one
  ## ticks after it are real `noop`s. The turn ends early only on a flinch or
  ## an episode end (tick step 12).
  sim.phase == Playing and not sim.turnActive

proc beginTurn*(sim: var SimServer): bool =
  ## Turn step 1: if the episode has already ended, stop; if the turn cap is
  ## reached, end it here. The cap fires at the START of the turn that would
  ## exceed it, so `turnsPlayed` can never pass `maxTurns` — a flinch that
  ## empties the queue mid-turn would otherwise let the next turn install
  ## anyway (the queue is empty, so `waitingForPlan` is true).
  if sim.phase != Playing:
    return false
  if sim.turnsPlayed >= sim.config.maxTurns:
    sim.finish(erComplete, edTurnCap)
    return false
  true

proc installPlan*(sim: var SimServer, primitives: seq[Primitive],
                  truncated: bool, dropped, unreachable: int) =
  ## The turn's expanded queue, already truncated to `turnTicks`. Nothing
  ## carries over to the next turn.
  sim.queue = primitives
  sim.executed = @[]
  sim.turnTick = 0
  sim.turnActive = true
  sim.planTruncated = truncated
  sim.lastDropped = dropped
  sim.lastUnreachable = unreachable
  sim.lastInterrupted = ""
  sim.actionsDropped += dropped
  sim.macrosUnreachable += unreachable
  inc sim.turnsPlayed
  sim.emit(SimEvent(kind: evTurn, i: sim.turnsPlayed, n: sim.tickCount))

# ---------------------------------------------------------------------------
#  The tick — §The game, the numbered resolution order
# ---------------------------------------------------------------------------

proc recordUnlock(sim: var SimServer, a: Achievement) =
  if sim.ledger.recordAchievement(a, sim.tickCount):
    sim.emit(SimEvent(kind: evAchievement, i: ord(a),
      n: sim.ledger.count, m: AchievementCount, a: $a))

proc stepTick*(sim: var SimServer) =
  ## ONE tick. This is the whole physics of the game and nothing else mutates
  ## the world.
  if sim.phase != Playing or not sim.turnActive:
    return

  # 1. tick += 1.
  inc sim.tickCount
  inc sim.turnTick

  # 2. Pop the next primitive. An empty queue is a real `noop`: the tick is
  #    spent, which is the cost of a plan that ran out.
  var primitive = pNoop
  if sim.queue.len > 0:
    primitive = sim.queue[0]
    sim.queue.delete(0)
  sim.executed.add(primitive)
  inc sim.primitivesExecuted

  # 3. Apply the primitive.
  let front = (x: sim.cog.x + FacingDx[sim.cog.facing],
               y: sim.cog.y + FacingDy[sim.cog.facing])
  let target = sim.herd.creatureAt(front.x, front.y)
  let now = sim.runTick()
  let outcome = sim.cog.applyPrimitive(sim.world, primitive, sim.config.seed,
    now, sim.config.plantRipenTicks, target >= 0)
  ## `applyPrimitive` never writes the world: every terrain change lands
  ## through `setTerrain`, the ONE door that also maintains the incremental
  ## terrain digest, so the digest can never drift from the grid.
  for change in outcome.changes:
    sim.setTerrain(change.x, change.y, change.terrain)
  for entry in outcome.ripen:
    sim.world.ripenAt[entry.slot] = entry.at
    if entry.slot notin sim.ripening:
      sim.ripening.add(entry.slot)

  var flinch = false
  var died = false
  case outcome.effect
  of peCollect:
    inc sim.blocksMined
    if outcome.mined: discard
    let unlock = collectAchievement(outcome.resource)
    sim.emit(SimEvent(kind: evCollect, x: outcome.x, y: outcome.y,
      n: sim.cog.inventory[outcome.resource], a: $outcome.resource))
    if unlock.ok:
      sim.recordUnlock(unlock.a)
  of peDrink:
    if outcome.amount > 0:
      sim.emit(SimEvent(kind: evDrink, n: sim.cog.drink()))
      sim.recordUnlock(aCollectDrink)
  of peEatPlant:
    if outcome.amount > 0:
      sim.emit(SimEvent(kind: evEat, n: sim.cog.food(), a: "plant"))
      sim.recordUnlock(aEatPlant)
  of pePlace:
    inc sim.blocksPlaced
    sim.emit(SimEvent(kind: evPlace, x: outcome.x, y: outcome.y,
      a: $outcome.placed))
    let unlock = placeAchievement(outcome.placed)
    if unlock.ok:
      sim.recordUnlock(unlock.a)
  of peCraft:
    inc sim.itemsCrafted
    sim.emit(SimEvent(kind: evCraft, a: $outcome.crafted))
    sim.recordUnlock(craftAchievement(outcome.crafted))
  of peSleep:
    inc sim.ticksAsleep
    if sim.cog.sleepRun == 1:
      sim.emit(SimEvent(kind: evSleep, a: "start"))
  of peAttack:
    if target >= 0:
      sim.damageDealt += outcome.damage
      sim.herd.list[target].hp -= outcome.damage
      if sim.herd.list[target].hp <= 0:
        let kind = sim.herd.list[target].kind
        sim.herd.list[target].alive = false
        sim.emit(SimEvent(kind: evKill, x: front.x, y: front.y, a: $kind))
        case kind
        of ckCow:
          inc sim.cowsEaten
          discard sim.cog.gain(vFood, 6)
          sim.emit(SimEvent(kind: evEat, n: sim.cog.food(), a: "cow"))
        of ckZombie: inc sim.zombiesKilled
        of ckSkeleton: inc sim.skeletonsKilled
        of ckArrow: discard
        let unlock = killAchievement(kind)
        if unlock.ok:
          sim.recordUnlock(unlock.a)
        sim.herd.compact()
  of peLava:
    sim.deathCause = dcLava
    died = true
    flinch = true
  else:
    discard

  if outcome.wokeRested:
    sim.emit(SimEvent(kind: evSleep, a: "end", n: sim.cog.energy()))
    sim.recordUnlock(aWakeUp)

  # 4. Vitals.
  if not died:
    let vitals = sim.cog.stepVitals(now, sim.config.foodTicks,
      sim.config.drinkTicks, sim.config.energyTicks, sim.config.regenTicks,
      sim.config.starveTicks)
    if vitals.regenerated:
      sim.emit(SimEvent(kind: evHeal, n: sim.cog.health()))
    for vital in [vFood, vDrink, vEnergy]:
      if vitals.starved[vital]:
        sim.emit(SimEvent(kind: evStarve, n: sim.cog.health(), a: $vital))
        if sim.cog.health() <= 0 and sim.deathCause == dcNone:
          sim.deathCause = starvationCause(vital)

  # 5. World tick: saplings ripen, the day/night phase is recomputed, and at
  #    the first tick of a new day zombies above ground burn.
  #    Only the cells that actually carry a ripen timer are visited — there
  #    are never more than a handful, and a 4096-cell sweep every tick is a
  #    cost the wasm viewer pays 1344 times for nothing.
  var stillRipening: seq[int]
  for slot in sim.ripening:
    if sim.world.cells[slot] != tSapling or sim.world.ripenAt[slot] <= 0:
      sim.world.ripenAt[slot] = 0
      continue
    if now >= sim.world.ripenAt[slot]:
      sim.setTerrain(slot mod WorldSize, slot div WorldSize, tRipePlant)
      sim.world.ripenAt[slot] = 0
    else:
      stillRipening.add(slot)
  sim.ripening = stillRipening
  let daylight = sim.isDaylight()
  if daylight != sim.lastPhaseWasDay:
    if daylight:
      inc sim.daysSurvived
      sim.emit(SimEvent(kind: evDaybreak, i: sim.dayOf()))
      let burned = sim.herd.burnAtDawn(sim.world)
      if burned > 0:
        sim.emit(SimEvent(kind: evBurn, n: burned))
        sim.herd.compact()
    else:
      inc sim.nightsSurvived
      sim.emit(SimEvent(kind: evNightfall, i: sim.dayOf()))
    sim.lastPhaseWasDay = daylight

  # 6. Spawns: one bounded attempt each for cow, zombie, skeleton.
  if not died:
    let caps = [(ckCow, if daylight: sim.config.maxCows else: 0),
                (ckZombie, if daylight: 0 else: sim.config.maxZombies),
                (ckSkeleton, sim.config.maxSkeletons)]
    for (kind, cap) in caps:
      if sim.herd.trySpawn(sim.world, kind, cap, sim.config.seed,
                           now, sim.cog.x, sim.cog.y):
        let last = sim.herd.list[^1]
        if kind in {ckZombie, ckSkeleton} and
            chebyshev(last.x, last.y, sim.cog.x, sim.cog.y) <= ViewSize div 2:
          sim.emit(SimEvent(kind: evSpawn, x: last.x, y: last.y, a: $kind))

  # 7. Creatures act, in the stable creature order.
  if not died:
    let hits = sim.herd.stepCreatures(sim.world, sim.cog, sim.config.seed, now)
    for hit in hits:
      sim.damageTaken += hit.amount
      flinch = true
      sim.lastInterrupted = "hurt_by_" & $hit.by
      sim.emit(SimEvent(kind: evHurt, x: hit.x, y: hit.y, n: hit.amount,
        m: sim.cog.health(), a: $hit.by))
      if sim.cog.asleep:
        sim.cog.asleep = false
        sim.cog.sleepRun = 0
      if sim.cog.health() <= 0 and sim.deathCause == dcNone:
        sim.deathCause = damageCauseOf(hit.by)
    sim.herd.compact()

  # 8. Achievements are recorded at the moment their predicate fires, above.

  # 9. Death check.
  if sim.cog.health() <= 0:
    if sim.deathCause == dcNone:
      sim.deathCause = dcStarvation
    sim.emit(SimEvent(kind: evDeath, a: $sim.deathCause, n: now))
    died = true

  # 10. Visibility: mark the 9 x 9 window as seen and merge it into the known
  #     map (last-seen terrain + seen_tick). `mergeVisible` returns how many
  #     cells were seen for the FIRST time, so `cellsSeen` is maintained
  #     INCREMENTALLY: a fresh 4096-cell count every tick is a quarter of the
  #     wasm viewer's per-tick budget for a number that changes by at most
  #     nine.
  sim.cellsSeenCount += sim.knownMap.mergeVisible(sim.world, sim.cog.x,
    sim.cog.y, sim.tickCount)

  # 11. Mix the tick into gameHash (done below, after the end evaluation, so
  #     the settled phase is part of the hashed state).
  if died:
    sim.finish(erComplete, edDeath)
  elif sim.ledger.allUnlocked():
    sim.finish(erComplete, edAllUnlocked)
  elif now >= sim.config.maxTicks:
    sim.finish(erComplete, edTickCap)

  # 12. Flinch / stop: if the cog took damage from a creature, an arrow or
  #     lava this tick, or the episode ended, BREAK OUT OF THE TICK LOOP — the
  #     remaining primitives of the turn are discarded and the next turn
  #     begins. Starvation damage does NOT flinch (a zeroed vital would
  #     otherwise burn the entire turn budget two ticks at a time).
  if sim.phase != Playing:
    sim.turnActive = false
    sim.queue = @[]
  elif flinch:
    if sim.turnTick < sim.config.turnTicks:
      inc sim.interrupts
    sim.turnActive = false
    sim.queue = @[]
  elif sim.turnTick >= sim.config.turnTicks:
    sim.turnActive = false
    sim.queue = @[]

  sim.recomputeHash()

proc step*(sim: var SimServer) =
  ## The lobby countdown, then the tick. Kept as one entry point so live play
  ## and replay playback cannot diverge on the phase transition.
  case sim.phase
  of Lobby:
    inc sim.tickCount
    inc sim.lobbyTicks
    ## A seat counts for the lobby only once it has REGISTERED. A joined but
    ## silent seat would otherwise start the game against the default script
    ## and report a champion as scripted (the grf-football scar).
    var ready = 0
    for entry in sim.players:
      if entry.connected and entry.registered: inc ready
    if ready >= sim.config.minPlayers or
        sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks:
      sim.phase = Playing
      sim.gameStartTick = sim.tickCount
      sim.startRun()
    sim.recomputeHash()
  of Playing:
    sim.stepTick()
  of GameOver:
    inc sim.tickCount
    sim.recomputeHash()

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  if sim.phase != Lobby: 0
  else: max(0, (sim.config.lobbyJoinTimeoutTicks - sim.lobbyTicks) div TargetFps)

proc effectiveMaxTicks*(sim: SimServer): int =
  max(1, sim.config.maxTicks + sim.gameStartTick)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.phase = Lobby
  result.gameEventLoggingEnabled = true
  result.endRule = edNone
  result.endReason = erComplete
  result.deathCause = dcNone
  result.ledger = initLedger()
  result.deadSeats = newSeq[bool](max(1, config.numAgents))
  result.policyKinds = newSeq[string](max(1, config.numAgents))
  for i in 0 ..< result.policyKinds.len:
    result.policyKinds[i] = "scripted"
  result.recomputeHash()

# ---------------------------------------------------------------------------
#  Roster
# ---------------------------------------------------------------------------

proc addPlayer*(sim: var SimServer, name: string, slot: int, token: string,
                trusted = false): int =
  ## Seats one player. Returns the roster index, or -1 when the slot is taken
  ## or the token does not match.
  if slot < 0 or slot >= sim.seatCount():
    return -1
  for entry in sim.players:
    if entry.slot == slot:
      return -1
  if not trusted and sim.config.tokens.len > slot and
      sim.config.tokens[slot].len > 0 and sim.config.tokens[slot] != token:
    return -1
  sim.players.add(RosterEntry(
    name: name, slot: slot, token: token, joinOrder: slot,
    connected: true, alias: seatAlias(slot)))
  sim.players.len - 1

proc removePlayerAt*(sim: var SimServer, index: int) =
  if index >= 0 and index < sim.players.len:
    sim.players[index].connected = false
    if sim.players[index].slot < sim.deadSeats.len:
      sim.deadSeats[sim.players[index].slot] = true

proc seatName*(sim: SimServer, slot: int): string =
  for entry in sim.players:
    if entry.slot == slot and entry.name.len > 0:
      return entry.name
  "Baseline (" & $(slot + 1) & ")"

proc compactFeedRecord*(record: string): string =
  ## The feed's view of a control record. The `directive` record carries the
  ## WHOLE observation (`view`) so the replay explains every decision — three
  ## or four kilobytes each — and `buildStateJson` ships the feed records in
  ## EVERY chrome frame. Keeping the observation there would re-parse and
  ## re-serialise a couple of hundred kilobytes of JSON per frame inside the
  ## wasm module and again in the browser, which is a frozen viewer, not a
  ## slow one. The replay bytes keep the observation; the feed does not.
  if record.len == 0 or record[0] != '{':
    return record
  var node: JsonNode
  try:
    node = parseJson(record)
  except CatchableError:
    return record
  if node.kind != JObject:
    return record
  ## `view` is the whole observation, `actions` and `executed` are the input
  ## log: all three belong in the REPLAY BYTES and none of them is drawn.
  ## `pushControlEvents` derives the `plan` event's verb list from the FULL
  ## record before this ever runs, so nothing the feed shows is lost.
  for key in ["view", "actions", "executed"]:
    if node.hasKey(key):
      node.delete(key)
  $node

proc pushFeedDirective*(sim: var SimServer, record: string) =
  ## Control records ride the replay chat stream as JSON objects and drive the
  ## broadcast feed. They are re-applied at playback into NON-HASHED fields
  ## only and can never affect the simulation.
  sim.feedDirectives.add(compactFeedRecord(record))
  ## The feed shows at most six rows and the endcard is state, not history:
  ## sixteen records is more than any readout reads, and every one of them
  ## rides in EVERY chrome frame.
  if sim.feedDirectives.len > 16:
    sim.feedDirectives.delete(0)

# ---------------------------------------------------------------------------
#  The seat's observation
# ---------------------------------------------------------------------------

proc viewRows*(sim: SimServer): seq[string] =
  ## Nine strings of nine glyphs, WORLD-ORIENTED, the cog at the centre
  ## reading `@`. A cell holding a creature reads that creature's glyph;
  ## otherwise the terrain glyph.
  let origin = viewOrigin(sim.cog.x, sim.cog.y)
  for j in 0 ..< ViewSize:
    var row = newString(ViewSize)
    for i in 0 ..< ViewSize:
      let
        x = origin.x + i
        y = origin.y + j
      if x == sim.cog.x and y == sim.cog.y:
        row[i] = CogGlyph
        continue
      let creature = sim.herd.creatureAt(x, y)
      if creature >= 0:
        row[i] = CreatureGlyphs[sim.herd.list[creature].kind]
      else:
        row[i] = sim.world.at(x, y).glyphOf()
    result.add(row)

proc nearestKnown*(sim: SimServer, terrain: Terrain): tuple[found: bool; x, y,
                                                            d: int] =
  var best = -1
  for slot in 0 ..< WorldCells:
    let entry = sim.knownMap.cells[slot]
    if not entry.seen or entry.terrain != terrain:
      continue
    let
      x = slot mod WorldSize
      y = slot div WorldSize
      d = chebyshev(x, y, sim.cog.x, sim.cog.y)
    if best < 0 or d < best:
      best = d
      result = (true, x, y, d)

const NearestTerrains* = [tTree, tWater, tStone, tCoal, tIron, tDiamond, tLava,
                          tTable, tFurnace, tRipePlant]

proc nearestJson(sim: SimServer): JsonNode =
  result = newJObject()
  for terrain in NearestTerrains:
    let spot = sim.nearestKnown(terrain)
    result[$terrain] =
      if spot.found: %*{"x": spot.x, "y": spot.y, "d": spot.d}
      else: newJNull()

proc landmarksJson(sim: SimServer): JsonNode =
  ## Up to MaxLandmarks other known notable cells, sorted ascending by `d`
  ## then (y, x), never repeating a cell already in `nearest`.
  var taken: seq[int]
  for terrain in NearestTerrains:
    let spot = sim.nearestKnown(terrain)
    if spot.found: taken.add(idx(spot.x, spot.y))
  var rows: seq[tuple[d, slot: int]]
  for slot in 0 ..< WorldCells:
    let entry = sim.knownMap.cells[slot]
    if not entry.seen or entry.terrain notin NearestTerrains:
      continue
    if slot in taken:
      continue
    rows.add((chebyshev(slot mod WorldSize, slot div WorldSize, sim.cog.x,
                        sim.cog.y), slot))
  rows.sort(proc (a, b: tuple[d, slot: int]): int =
    if a.d != b.d: cmp(a.d, b.d) else: cmp(a.slot, b.slot))
  result = newJArray()
  for row in rows:
    if result.len >= MaxLandmarks:
      break
    result.add(%*{
      "what": $sim.knownMap.cells[row.slot].terrain,
      "x": row.slot mod WorldSize, "y": row.slot div WorldSize, "d": row.d,
      "seen_tick": sim.knownMap.cells[row.slot].seenTick})

proc hostileCells*(sim: SimServer): seq[int] =
  ## The cells of hostiles CURRENTLY in `threats`. The `goto` BFS refuses to
  ## route through them, which is what keeps a plan from walking into a
  ## zombie the seat can already see.
  for creature in sim.herd.list:
    if creature.alive and creature.kind in {ckZombie, ckSkeleton} and
        chebyshev(creature.x, creature.y, sim.cog.x, sim.cog.y) <=
          ViewSize div 2:
      result.add(idx(creature.x, creature.y))

proc threatsJson*(sim: SimServer): JsonNode =
  ## Every creature CURRENTLY in the 9 x 9 view. Creatures are never
  ## remembered outside the view.
  result = newJArray()
  for creature in sim.herd.list:
    if not creature.alive:
      continue
    let d = chebyshev(creature.x, creature.y, sim.cog.x, sim.cog.y)
    if d > ViewSize div 2:
      continue
    result.add(%*{"what": $creature.kind, "x": creature.x, "y": creature.y,
                  "d": d})

proc observationJson*(sim: SimServer, includeNotes: bool): JsonNode =
  ## Everything the seat may legitimately know, and nothing else. The episode
  ## SEED, every unobserved cell, every noise-field value and generator
  ## threshold, creature HP, the spawn schedule, the 1-in-10 sapling draw, the
  ## cog's own SCORE, `parAchievements` and its own real player name are ALL
  ## hidden.
  var view = newJArray()
  for row in sim.viewRows():
    view.add(%row)
  var region = newJArray()
  for row in sim.knownMap.regionRows():
    region.add(%row)
  var unlocked = newJArray()
  var locked = newJArray()
  for a in Achievement:
    if sim.ledger.unlocked[a]: unlocked.add(%($a)) else: locked.add(%($a))
  var executed = newJArray()
  for primitive in sim.executed:
    executed.add(%($primitive))
  var inventory = newJObject()
  for resource in Resource:
    inventory[$resource] = %sim.cog.inventory[resource]
  var tools = newJObject()
  for tool in Tool:
    tools[$tool] = %sim.cog.tools[tool]
  let front = sim.cog.ahead()
  result = %*{
    "you": seatAlias(0),
    "turn": sim.turnsPlayed + 1,
    "tick": sim.tickCount,
    "world": {
      "size": WorldSize, "view": ViewSize, "region": RegionSize,
      "legend": {
        ".": "grass", ",": "sand", "~": "water", "#": "stone",
        "=": "path", "T": "tree", "c": "coal", "i": "iron",
        "D": "diamond", "!": "LAVA (instant death)", "B": "bedrock",
        "t": "table", "f": "furnace", "p": "sapling", "Y": "ripe plant",
        "U": "cow", "Z": "zombie", "K": "skeleton", "^": "arrow",
        "@": "you", "?": "never seen"
      }
    },
    "time": {
      "day": sim.dayOf(),
      "phase": (if sim.isDaylight(): "day" else: "night"),
      "ticks_to_phase_change": sim.ticksToPhaseChange(),
      "ticks_left": max(0, sim.config.maxTicks - sim.survivalTicks()),
      "turns_left": max(0, sim.config.maxTurns - sim.turnsPlayed)
    },
    "agent": {
      "x": sim.cog.x, "y": sim.cog.y, "facing": $sim.cog.facing,
      "asleep": sim.cog.asleep,
      "health": sim.cog.health(), "food": sim.cog.food(),
      "drink": sim.cog.drink(), "energy": sim.cog.energy(),
      "ahead": {"glyph": $sim.world.at(front.x, front.y).glyphOf(),
                "what": $sim.world.at(front.x, front.y),
                "x": front.x, "y": front.y}
    },
    "inventory": inventory,
    "tools": tools,
    "near": {"table": sim.world.nearTerrain(sim.cog, tTable),
             "furnace": sim.world.nearTerrain(sim.cog, tFurnace)},
    "view": view,
    "region": region,
    "nearest": sim.nearestJson(),
    "landmarks": sim.landmarksJson(),
    "threats": sim.threatsJson(),
    "achievements": {
      "count": sim.ledger.count, "of": AchievementCount,
      "unlocked": unlocked, "locked": locked
    },
    "last_plan": {
      "executed": executed,
      "truncated": sim.planTruncated,
      "dropped": sim.lastDropped,
      "unreachable": sim.lastUnreachable,
      "interrupted": sim.lastInterrupted
    }
  }
  if includeNotes:
    result["notes"] = %sim.notes

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

proc toolsOwned*(sim: SimServer): seq[string] =
  for tool in Tool:
    if sim.cog.tools[tool]: result.add($tool)

proc runResultsJson*(sim: SimServer): string =
  ## The closed results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set in the SAME commit — Coworld schemas are closed and undeclared keys
  ## are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    dead = newJArray()
    kinds = newJArray()
    ids = newJArray()
    unlocked = newJArray()
    ticks = newJArray()
    tools = newJArray()
  let met = sim.achievementsUnlocked() >= sim.config.parAchievements
  for slot in 0 ..< sim.seatCount():
    names.add(%sim.seatName(slot))
    aliases.add(%seatAlias(slot))
    scores.add(%sim.score())
    win.add(%met)
    dead.add(%(if slot < sim.deadSeats.len: sim.deadSeats[slot] else: true))
    kinds.add(%(if slot < sim.policyKinds.len: sim.policyKinds[slot]
                else: "scripted"))
  for a in Achievement:
    ids.add(%($a))
    unlocked.add(%sim.ledger.unlocked[a])
    ticks.add(%sim.ledger.tick[a])
  for name in sim.toolsOwned():
    tools.add(%name)
  var winner: JsonNode = newJNull()
  if met:
    winner = %0
  $(%*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": winner,
    "reason": $sim.endReason,
    "endRule": $sim.endRule,
    "variant": sim.config.variant,
    "seed": sim.config.seed,
    "achievementIds": ids,
    "achievementUnlocked": unlocked,
    "achievementTick": ticks,
    "achievementsUnlocked": sim.achievementsUnlocked(),
    "achievementsOf": AchievementCount,
    "parAchievements": sim.config.parAchievements,
    "survivalTicks": sim.survivalTicks(),
    "daysSurvived": sim.daysSurvived,
    "nightsSurvived": sim.nightsSurvived,
    "deathCause": $sim.deathCause,
    "finalHealth": sim.cog.health(),
    "finalFood": sim.cog.food(),
    "finalDrink": sim.cog.drink(),
    "finalEnergy": sim.cog.energy(),
    "invWood": sim.cog.inventory[rWood],
    "invStone": sim.cog.inventory[rStone],
    "invCoal": sim.cog.inventory[rCoal],
    "invIron": sim.cog.inventory[rIron],
    "invDiamond": sim.cog.inventory[rDiamond],
    "invSapling": sim.cog.inventory[rSapling],
    "toolsOwned": tools,
    "cellsSeen": sim.knownMap.cellsSeen(),
    "cellsTotal": WorldCells,
    "damageTaken": sim.damageTaken,
    "damageDealt": sim.damageDealt,
    "zombiesKilled": sim.zombiesKilled,
    "skeletonsKilled": sim.skeletonsKilled,
    "cowsEaten": sim.cowsEaten,
    "blocksMined": sim.blocksMined,
    "blocksPlaced": sim.blocksPlaced,
    "itemsCrafted": sim.itemsCrafted,
    "ticksAsleep": sim.ticksAsleep,
    "interrupts": sim.interrupts,
    "primitivesExecuted": sim.primitivesExecuted,
    "actionsDropped": sim.actionsDropped,
    "macrosUnreachable": sim.macrosUnreachable,
    "repliesRepaired": sim.repliesRepaired,
    "finalTick": sim.survivalTicks(),
    "turnsPlayed": sim.turnsPlayed,
    "policyKinds": kinds,
    "llmTurns": sim.llmTurns,
    "fallbackTurns": sim.fallbackTurns,
    "deadSeats": dead,
    "stopDetail": sim.stopDetail
  })

proc playerResultsJson*(sim: SimServer): string = sim.runResultsJson()
