## The reply schema: what a policy (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and what happens to an entry that does not validate.
##
## Both policy kinds emit the SAME object through the SAME validator, which is
## what makes the bounded-orders test in `tests/test_crafter_driver.nim`
## meaningful.
##
## INVALID ACTIONS ARE DROPPED, NEVER REWRITTEN. Turning a malformed `goto`
## into a `move_down` could walk the cog into lava on the game's own
## initiative, so the entry is removed, counted in `repliesRepaired`, and
## reported back as `dropped` next turn.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES and every
## truncation lands on a rune boundary. Slicing a string by BYTE index
## anywhere on the path to the replay is forbidden: a byte-truncated
## multi-byte character renders fine in a browser and then fails a strict
## UTF-8 parser.

import std/[json, strutils, unicode]
import sim_types, driver

type
  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  Directive* = object
    ## One seat's whole plan for one turn.
    actions*: seq[Action]
    say*: string               ## <= MaxSayRunes, sanitised on rune boundaries
    notes*: string             ## <= MaxNoteRunes, echoed to this seat only
    source*: DirectiveSource
    latencyMs*: int
    dropped*: int              ## entries that did not validate
    overCap*: int              ## entries past maxActionsPerTurn

  DirectiveError* = object of ValueError

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readInteger(node: JsonNode): tuple[ok: bool, value: int] =
  ## One integer field: an int, a whole float, or a numeric string. Anything
  ## else reports `ok = false` so the caller DROPS the entry rather than
  ## inventing a destination.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let value = node.getFloat()
    if value != value or value > 1.0e9 or value < -1.0e9: (false, 0)
    else: (true, int(value))
  of JString:
    try: (true, parseInt(node.getStr().strip()))
    except ValueError: (false, 0)
  else:
    (false, 0)

proc actionEntries(payload: JsonNode): seq[JsonNode] =
  ## `actions` accepted as an array of objects; a bare string entry (`"do"`)
  ## is accepted too, because models emit that shape.
  let node = payload{"actions"}
  if node.isNil or node.kind != JArray:
    return @[]
  for item in node:
    if item.kind == JObject:
      result.add(item)
    elif item.kind == JString:
      result.add(%*{"act": item.getStr()})

proc verbOf(entry: JsonNode): string =
  ## `act` is the schema's key; `do` is accepted as an alias because a model
  ## that has seen the starter's schema emits it.
  var text = entry{"act"}.getStr()
  if text.len == 0:
    let alternative = entry{"do"}
    if not alternative.isNil and alternative.kind == JString:
      text = alternative.getStr()
  text.truncateRunes(20)

proc parseDirective*(payload: JsonNode, maxActionsPerTurn: int): Directive =
  ## Turns one parsed reply into a legal plan. Raises DirectiveError only when
  ## the payload is not a JSON object — a reply with a valid `say` but no
  ## `actions` is USABLE (the turn is spent idling and the narration is
  ## delivered), which is the one condition the retry and the scripted
  ## fallback do NOT exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.source = dsLlm
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeNote(payload{"notes"}.getStr())
  var seen = 0
  for entry in payload.actionEntries():
    inc seen
    if seen > maxActionsPerTurn:
      inc result.overCap
      continue
    let parsed = parseActionKind(entry.verbOf())
    if not parsed.ok:
      inc result.dropped
      continue
    var action = Action(kind: parsed.kind, n: 1)
    case parsed.kind
    of akGoto:
      let
        gx = readInteger(entry{"x"})
        gy = readInteger(entry{"y"})
      if not gx.ok or not gy.ok:
        inc result.dropped
        continue
      action.x = clamp(gx.value, 0, WorldSize - 1)
      action.y = clamp(gy.value, 0, WorldSize - 1)
    of akMove:
      let dir = parseFacing(entry{"dir"}.getStr().truncateRunes(5))
      if not dir.ok:
        inc result.dropped
        continue
      action.dir = dir.dir
    else: discard
    let repeat = repeatable(parsed.kind)
    if repeat.ok:
      let count = readInteger(entry{"n"})
      action.n = if count.ok: clamp(count.value, 1, repeat.limit) else: 1
    result.actions.add(action)

proc actionsJson*(actions: seq[Action]): JsonNode =
  result = newJArray()
  for action in actions:
    var item = %*{"act": $action.kind}
    case action.kind
    of akGoto:
      item["x"] = %action.x
      item["y"] = %action.y
    of akMove:
      item["dir"] = %($action.dir)
      item["n"] = %action.n
    else:
      if repeatable(action.kind).ok:
        item["n"] = %action.n
    result.add(item)

proc primitivesJson*(primitives: seq[Primitive]): JsonNode =
  result = newJArray()
  for primitive in primitives:
    result.add(%($primitive))

proc directiveRecord*(directive: Directive, turn, tick, slot: int,
                      alias: string, executed: seq[Primitive],
                      truncated: bool, dropped, unreachable: int,
                      interrupted: string, view: JsonNode): JsonNode =
  ## The replay chat record for one turn. Re-applied at playback to install
  ## the SAME primitive queue and to drive the broadcast feed and
  ## `tools/replay_summary.py`.
  %*{
    "k": "directive",
    "turn": turn,
    "tick": tick,
    "slot": slot,
    "alias": alias,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "actions": actionsJson(directive.actions),
    "executed": primitivesJson(executed),
    "truncated": truncated,
    "dropped": dropped,
    "unreachable": unreachable,
    "interrupted": interrupted,
    "say": directive.say,
    "view": (if view.isNil: newJNull() else: view)
  }

proc boundedDirectiveRecord*(directive: Directive, turn, tick, slot: int,
                             alias: string, executed: seq[Primitive],
                             truncated: bool, dropped, unreachable: int,
                             interrupted: string, view: JsonNode): string =
  ## The serialized record, guaranteed <= MaxDirectiveRunes. `say` is the only
  ## unbounded-in-practice field, so it is what shrinks, and the cut still
  ## lands on a RUNE boundary. NEVER cut the SERIALIZED string — that would
  ## emit broken JSON, which is the exact failure the rune rule exists to
  ## prevent.
  ##
  ## `view` IS THE LAST THING TO GO, not the first: the note's whole reason for
  ## mirroring the observation into the record is that "the replay explains
  ## every decision", and a record with `"view": null` explains nothing. The
  ## cap is sized so a whole observation plus a full-cap `say` fits, so this
  ## shrinks `say` to nothing before it will drop the view at all.
  var trimmed = directive
  result = $trimmed.directiveRecord(turn, tick, slot, alias, executed,
    truncated, dropped, unreachable, interrupted, view)
  if result.runeLen <= MaxDirectiveRunes:
    return
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and trimmed.say.len > 0 and
      guard < 12:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(
      max(0, trimmed.say.runeLen - max(8, trimmed.say.runeLen div 2)))
    result = $trimmed.directiveRecord(turn, tick, slot, alias, executed,
      truncated, dropped, unreachable, interrupted, view)
  if result.runeLen <= MaxDirectiveRunes:
    return
  ## Only now: an observation so large that the record cannot hold it even
  ## with no `say` at all.
  result = $trimmed.directiveRecord(turn, tick, slot, alias, executed,
    truncated, dropped, unreachable, interrupted, nil)

proc parseRecordedActions*(node: JsonNode): seq[Primitive] =
  ## Playback: the `executed` array of a `directive` record, back into the
  ## primitive queue. This game's ENTIRE input log.
  if node.isNil or node.kind != JArray:
    return @[]
  for item in node:
    if item.kind != JString:
      continue
    let parsed = parsePrimitive(item.getStr())
    if parsed.ok:
      result.add(parsed.primitive)
