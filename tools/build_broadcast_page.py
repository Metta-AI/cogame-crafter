#!/usr/bin/env python3
"""Derive `client/replay_broadcast.html` from the coworld-ctf starter page.

The pin is "the starter's page PLUS an appended game block" — never a
from-scratch page that reuses the starter's ids (cogame-gridlock, 2026-08-23).
So the committed page is DERIVED, not authored: this script takes the
starter's bytes, applies an EXPLICIT, ENUMERATED edit list (the elements the
design note lists as removed and the vocabulary re-mapping table), and appends
`client/crafter_block.html` under the banner comment.

Every edit is an exact-substring replacement that must match exactly once, so
a starter change that invalidates an edit fails loudly here instead of
silently shipping a half-edited page.

    python3 tools/build_broadcast_page.py --starter /workspace/starters/coworld-ctf
    python3 tools/build_broadcast_page.py --starter <path> --check

`--check` re-derives the page and diffs it against the committed one. CI runs
it only when the starter mount is present; `tests/test_crafter_viewer.nim`
asserts the committed artifact's structure unconditionally.
"""
import argparse
import difflib
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- the elements the design note lists as removed -------------------------
# Markup blocks, matched exactly. `#viewpanel` is KEPT — zoom bar, minimap and
# all: the world is 64x64 cells (1536x1536 native px) and the default view
# shows 15 of them, so this board genuinely is larger than the frame, which is
# exactly the condition the pin names.
MARKUP_REMOVALS = [
    # #povBadge: with one seat there is nothing to select
    ("""    <div id="povBadge">👁 POV lens — click to clear</div>
""", """    <!-- CRAFTER: the POV badge is REMOVED — one seat, nothing to select. -->
"""),
    # inside the KEPT #fpv: the cog has no hit points and no gear
    ("""        <span class="fpv-hp" id="fpv-hp"></span>
        <span class="fpv-gear" id="fpv-gear"></span>
""", """        <!-- CRAFTER: hit-point pips and the gear line are REMOVED. -->
"""),
    # the un-fogged tactical inset is redundant when the main board IS it
    ("""      <!-- Un-fogged tactical minimap: arena walls + all units + hearts + the
           POV seat's vision wedge. Full context, no fog of war. -->
      <div class="fpv-map" id="fpv-map">
        <canvas id="fpv-map-canvas"></canvas>
      </div>
""", """      <!-- CRAFTER: the un-fogged tactical inset is REMOVED — the main
           board already IS the un-fogged view; this panel now draws the
           agent's own 7x7 window instead. -->
"""),
]

# --- JS re-pointing --------------------------------------------------------
# The starter's wiring for the removed elements is LEFT INTACT and pointed at
# DETACHED nodes. That keeps every code path alive and byte-identical in
# behaviour while no removed id survives in the document — the alternative,
# excising the wiring, is the rewrite the pin forbids.
JS_REWRITES = [
    ("""    var badge = $('povBadge');""",
     """    var badge = cfDetached('div');   // CRAFTER: POV badge removed"""),
    ("""  // pov clear (togglePov lives in the shared chrome, driven via ctx.sendPov)
  $('povBadge').addEventListener('click', function () { send('v:-1'); });""",
     """  // CRAFTER: the POV-clear click target is removed with its badge."""),
    ("""    var hpEl = $('fpv-hp'), hpHtml = '';""",
     """    var hpEl = cfDetached('span'), hpHtml = '';   // CRAFTER: no hit points"""),
    ("""    var gearEl = $('fpv-gear'), bits = [];""",
     """    var gearEl = cfDetached('span'), bits = [];   // CRAFTER: no gear"""),
    ("""  var fpvMapEl = $('fpv-map'), fpvMapCanvas = $('fpv-map-canvas'), fpvMapCtx = null;""",
     """  var fpvMapEl = cfDetached('div'), fpvMapCanvas = cfDetached('canvas'),
      fpvMapCtx = null;   // CRAFTER: the tactical inset is removed"""),
    # There is ONE cog and it is red: the blue/green/yellow locker-room webps
    # are deleted with the teams they belonged to, so the loading scene must
    # not request them (four 404s per open otherwise).
    ("""    ['green', 'blue', 'yellow', 'red'].forEach(function (bot) {""",
     """    ['red'].forEach(function (bot) {"""),
    # The chrome context is built inside the page's own IIFE, so a harness
    # cannot reach it. Publish it: tools/ci/renderer_fixture.html drives the
    # SHIPPED chrome through its real context rather than a stand-in.
    ("""  if (window.PaintballChrome) window.PaintballChrome.install(PB_CTX);""",
     """  window.CF_CTX = PB_CTX;
  if (window.PaintballChrome) window.PaintballChrome.install(PB_CTX);"""),
    # The board is LARGER THAN THE FRAME here (64x64 cells, 1536x1536 native
    # px, 15 cells across by default), so the appended block arms a follow-cam
    # over the kept #viewpanel. The core lives inside the page's IIFE; publish
    # the handle rather than re-creating one.
    ("""  core.attachMinimap($('minimap-canvas'));""",
     """  window.CF_CORE = core;   // CRAFTER: the follow-cam drives this handle
  core.attachMinimap($('minimap-canvas'));"""),
    # The starter's dblclick / '0' resetView re-fits the board. Here it also
    # RE-ARMS the follow-cam and restores cameraCells, which is the design
    # note's rule; a user pan disarms it.
    ("""  canvas.addEventListener('dblclick', function (ev) {
    ev.preventDefault();
    core.resetView();
  });""",
     """  canvas.addEventListener('dblclick', function (ev) {
    ev.preventDefault();
    core.resetView();
    if (window.CrafterChrome && window.CrafterChrome.armFollow) {
      window.CrafterChrome.armFollow();
    }
  });"""),
]

# The detached-node helper, injected right after the page's own `$` alias.
DETACHED_HELPER = ("""  var $ = C.$;""", """  var $ = C.$;
  // CRAFTER: a DETACHED stand-in for an element this game removed. The
  // starter's wiring for those elements is kept verbatim and pointed here, so
  // it runs harmlessly and no removed id exists in the document.
  function cfDetached(tag) { return document.createElement(tag); }""")

# --- the vocabulary re-mapping table (design note, §Viewer) -----------------
VOCABULARY = [
    ("""<div class="ec-thead"><span>Player</span><span>K</span><span>D</span><span>Clstr</span><span>Cap</span></div>""",
     """<div class="ec-thead"><span>#</span><span>Achievement</span><span>Unlocked</span><span>Tick</span><span>Day</span></div>"""),
    ("""<div class="ec-thead"><span>Cog</span><span>Tags</span><span>Out</span><span>Paint</span></div>""",
     """<div class="ec-thead"><span>Cog</span><span>Unlocked</span><span>Survived</span><span>Score</span></div>"""),
    ("""<span class="fl-cap">Lives left</span>""",
     """<span class="fl-cap">Achievements</span>"""),
    ("""<span class="fl-cap">Hill time</span>""",
     """<span class="fl-cap">Ticks survived</span>"""),
    ("""<span class="momentum-label">LIVES LEAD</span>""",
     """<span class="momentum-label">ACHIEVEMENTS</span>"""),
    ("""<span class="lives-label pb-lbl">Hill</span>""",
     """<span class="vital-label pb-lbl">Carrying</span>"""),
    ("""<span class="lives-label">Lives</span>""",
     """<span class="vital-label">Health</span>"""),
    # The locker-room loading scene: the plate is the starter's, the prep-talk
    # lines are re-written for a cog waking up alone in a wilderness.
    ("""Filling hoppers with fresh paint&hellip;""",
     """Generating the world&hellip;"""),
    ("""      'Filling hoppers with fresh paint…',
      'Pump check: one, two. One, two…',
      'Polishing visors to a mirror shine…',
      'Shaking the paint pods awake…',
      'Squats. Even robots warm up…',
      'Topping off the CO₂…',
      'Chalking up the wheels…',
      'Reviewing the game plan…'""",
     """      'Generating the world…',
      'Salting the mountain with iron…',
      'Filling the lake…',
      'Planting the forest…',
      'Burying one diamond, very deep…',
      'Waking the cows…',
      'Counting the hours until dark…',
      'Twenty-two things you have never done…'"""),
    ("""In the locker room""", """Waiting for the cog"""),
    ("""Replay hash mismatch — showing recorded inputs""",
     """Replay hash mismatch at tick N — showing recorded actions"""),
    ("""<div class="fpv-cap" id="fpv-cap">EYES</div>""",
     """<div class="fpv-cap" id="fpv-cap">AGENT VIEW 9×9</div>"""),
    ("""title="Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)\"""",
     """title="Spoilers: achievements and the death on the timeline ahead of the playhead (o)\""""),
    # #zoom-read is re-labelled from FIT to the cells across; the game block
    # rewrites it every frame, and this is the pre-stream value.
    ("""<span id="zoom-read" aria-live="off">FIT</span>""",
     """<span id="zoom-read" aria-live="off">15 CELLS</span>"""),
]

# --- CSS rules for kinds this game never emits -----------------------------
# tests/test_crafter_viewer.nim asserts the set of `.beat-marker.<kind>`
# rules equals exactly the kinds the sim emits.
# `.beat-marker.kill` is RETARGETED, not removed: this game emits a `kill`
# beat and says KILLED A ZOMBIE in the feed.
DEAD_BEAT_KINDS = ["steal", "return", "capture",
                   "gamestart", "hillflip", "tagout", "gameover"]
# Every id/class the design note removes; a surviving mention fails the check.
REMOVED_NAMES = ["povBadge", "fpv-hp", "fpv-gear", "fpv-map"]

BANNER = "CRAFTER additions to the inherited coworld-ctf chrome"


def strip_css_comments(text, predicate):
    """Delete CSS comments that mention a name this game removed."""
    out = []
    i = 0
    while True:
        start = text.find("/*", i)
        if start < 0:
            out.append(text[i:])
            break
        end = text.find("*/", start)
        if end < 0:
            out.append(text[i:])
            break
        body = text[start:end + 2]
        out.append(text[i:start])
        if not predicate(body):
            out.append(body)
        i = end + 2
    return "".join(out)


def strip_css_rules(text, predicate):
    """Delete top-level CSS rules whose selector matches `predicate`."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        brace = text.find("{", i)
        if brace < 0:
            out.append(text[i:])
            break
        # A rule's selector starts after the previous '}' or ';'. When neither
        # is in range the selector starts at the cursor — NOT at 0, which
        # would drag the whole preceding file into the selector text and make
        # the at-rule guard below reject every rule after the first @media.
        last = max(text.rfind("}", i, brace), text.rfind(";", i, brace))
        start = i if last < 0 else last + 1
        selector = text[start:brace]
        depth = 0
        j = brace
        while j < n:
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        end = j + 1
        # At-rules wrap nested rules, so they are never removed wholesale;
        # their contents are scanned on the next pass through this function.
        bare = re.sub(r"/\*.*?\*/", " ", selector, flags=re.S)
        if predicate(selector) and "@" not in bare:
            out.append(text[i:start])
            i = end
            while i < n and text[i] == "\n":
                i += 1
            continue
        out.append(text[i:end])
        i = end
    return "".join(out)


def apply_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            "::error::edit %r matched %d times (expected exactly 1) — the "
            "starter page changed; update tools/build_broadcast_page.py"
            % (label, count))
    return text.replace(old, new)


def build(starter_page, block):
    text = starter_page

    for old, new in MARKUP_REMOVALS:
        text = apply_once(text, old, new, old[:60])
    text = apply_once(text, *DETACHED_HELPER, label="detached helper")
    for old, new in JS_REWRITES:
        text = apply_once(text, old, new, old[:60])
    for old, new in VOCABULARY:
        text = apply_once(text, old, new, old[:60])

    # Drop the CSS for beat kinds this game never emits and for the removed
    # elements.
    def dead(sel):
        s = sel.strip()
        for kind in DEAD_BEAT_KINDS:
            if ".beat-marker." + kind in s:
                return True
        for name in REMOVED_NAMES:
            if "#" + name in s or "." + name in s:
                return True
        return False

    def dead_comment(body):
        for name in REMOVED_NAMES:
            if name in body:
                return True
        for kind in DEAD_BEAT_KINDS:
            if ".beat-marker." + kind in body:
                return True
        return False

    # Only the <style> sections are CSS; running the rule scanner over the
    # whole document would desync its brace matching on the inline scripts.
    def edit_styles(page, fn):
        pieces = []
        cursor = 0
        while True:
            open_tag = page.find("<style>", cursor)
            if open_tag < 0:
                pieces.append(page[cursor:])
                break
            close_tag = page.find("</style>", open_tag)
            if close_tag < 0:
                pieces.append(page[cursor:])
                break
            body_start = open_tag + len("<style>")
            pieces.append(page[cursor:body_start])
            pieces.append(fn(page[body_start:close_tag]))
            cursor = close_tag
        return "".join(pieces)

    text = edit_styles(text, lambda css: strip_css_rules(css, dead))
    text = edit_styles(text, lambda css: strip_css_comments(css, dead_comment))

    # Cut the starter's own game block (everything from its banner comment)
    # and append this game's.
    marker = text.find("<!-- ============================================================\n     PAINTBALL additions")
    if marker < 0:
        raise SystemExit("::error::the starter's game-block banner is missing")
    prefix = text[:marker]
    text = prefix + block

    # The splice hook keeps its signatures; only the namespace is renamed.
    text = text.replace("window.PaintballChrome", "window.CrafterChrome")

    leftovers = sorted({n for n in REMOVED_NAMES
                        if re.search(r"[#'\"\.]" + re.escape(n) + r"\b", text)})
    if leftovers:
        raise SystemExit("::error::removed element names survive: %s"
                         % ", ".join(leftovers))
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--starter", default="/workspace/starters/coworld-ctf")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    starter_path = os.path.join(args.starter, "client", "replay_broadcast.html")
    if not os.path.exists(starter_path):
        print("starter page not present at %s; nothing to re-derive"
              % starter_path)
        return 0
    with open(starter_path, encoding="utf-8") as handle:
        starter_page = handle.read()
    with open(os.path.join(REPO, "client", "crafter_block.html"),
              encoding="utf-8") as handle:
        block = handle.read()

    built = build(starter_page, block)
    target = os.path.join(REPO, "client", "replay_broadcast.html")
    if args.check:
        with open(target, encoding="utf-8") as handle:
            current = handle.read()
        if current != built:
            diff = difflib.unified_diff(current.splitlines(),
                                        built.splitlines(),
                                        "committed", "re-derived", lineterm="")
            print("\n".join(list(diff)[:200]))
            raise SystemExit(
                "::error::client/replay_broadcast.html is not the derived page")
        print("client/replay_broadcast.html matches the derivation")
        return 0
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(built)
    print("wrote client/replay_broadcast.html (%d bytes)" % len(built))
    return 0


if __name__ == "__main__":
    sys.exit(main())
