## Endcard and chrome label re-mapping — design note §Tests item 40.
##
## A forked ctf endcard silently ships paintbot's vocabulary: nothing in the
## starter's tests, in `viewer_smoke.mjs` or in the label manifest covers
## SPECTATOR chrome strings, because `labels.nim` deliberately scopes itself to
## the POLICY contract. The re-labelings are therefore enumerated in the design
## note and enforced here.
##
## SCOPE. This test greps the strings a SPECTATOR READS — element text, CSS
## `content:` values and `title` / `aria-label` attributes — not class names or
## JS identifiers. `.hillchip` and `#lives-red` survive as INHERITED SELECTORS
## because the starter's own `renderScorebug` writes through them; removing
## them would mean rewriting the starter's renderer, which is exactly the
## rewrite the "chrome verbatim" pin forbids. Their VISIBLE TEXT is re-mapped,
## and that is what this test measures. The surviving selectors are listed
## below so the divergence is explicit rather than incidental.

import std/[strutils, unittest]
import crafter/sim
import helpers

const
  ## Spectator-facing paintbot vocabulary that must not survive.
  Forbidden = ["Lives left", "Hill time", "LIVES LEAD", ">Lives<", ">Hill<",
               ">Clstr<", ">Cap<", ">Tags<", ">Paint<", ">K<", ">D<",
               "Filling hoppers", "In the locker room", ">EYES<",
               "showing recorded inputs", "kills / flag story", ">FIT<",
               "Pump check"]
  ## INHERITED DEAD PATHS. The starter's renderer carries draw code for item
  ## kinds this sim can never emit — grenades, med kits, spray cans, shields.
  ## Deleting that code is a rewrite of `renderItems` / `renderSplat`, which
  ## is exactly what the "chrome verbatim" pin forbids, so the code stays and
  ## the EVENT VOCABULARY is what keeps it dead: nothing in `EventKind` can
  ## reach it. The names are listed so the divergence is explicit.
  InheritedDeadPaths = ["grenade", "medkit", "spray", "shield"]
  ## The transport verdict chip is re-labelled at runtime by the game block,
  ## because the shared chrome writes "RED WINS" into it from the frame's team
  ## key and chrome_common.js is byte-for-byte the starter's.
  VerdictRelabel = "' — PAR '"
  ## Each re-mapped string, present exactly once.
  Remapped = [
    "<span>#</span><span>Achievement</span><span>Unlocked</span><span>Tick</span><span>Day</span>",
    "<span>Cog</span><span>Unlocked</span><span>Survived</span><span>Score</span>",
    "<span class=\"fl-cap\">Achievements</span>",
    "<span class=\"fl-cap\">Ticks survived</span>",
    "<span class=\"momentum-label\">ACHIEVEMENTS</span>",
    "<span class=\"vital-label pb-lbl\">Carrying</span>",
    "<span class=\"vital-label\">Health</span>",
    "Generating the world&hellip;",
    "Waiting for the cog",
    "showing recorded actions",
    "<div class=\"fpv-cap\" id=\"fpv-cap\">AGENT VIEW 9×9</div>",
    "Spoilers: achievements and the death on the timeline ahead of the playhead (o)",
    "<span id=\"zoom-read\" aria-live=\"off\">15 CELLS</span>"]
  ## Inherited SELECTORS the starter's own renderers write through. Documented
  ## divergence: the names stay, the visible text is re-mapped.
  InheritedSelectors = ["hillchip", "lives-num", "lives-line", "pb-lbl"]

suite "crafter endcard labels":

  test "40. no spectator-facing paintbot vocabulary survives":
    let page = readRepo("client/replay_broadcast.html")
    for phrase in Forbidden:
      if phrase in page:
        checkpoint("forbidden spectator string still in the page: " & phrase)
      check phrase notin page
    for phrase in Remapped:
      var count = 0
      var cursor = 0
      while true:
        let hit = page.find(phrase, cursor)
        if hit < 0: break
        inc count
        cursor = hit + 1
      if count != 1:
        checkpoint("re-mapped string appears " & $count & " times: " & phrase)
      check count == 1
    ## The verdict chip is re-labelled for the one cog.
    check VerdictRelabel in page
    check "cfEl('win-chip')" in page
    ## The documented divergence is real and bounded: these selectors survive,
    ## and nothing else paintbot-shaped does.
    for selector in InheritedSelectors:
      check selector in page
    ## The inherited item-draw paths survive as CODE and are unreachable as
    ## BEHAVIOUR: no `EventKind` this sim emits names any of them, so nothing
    ## the game block or the sim produces can light them up.
    for name in InheritedDeadPaths:
      check name in page
      for kind in EventKind:
        check $kind != name
