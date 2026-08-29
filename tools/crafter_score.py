#!/usr/bin/env python3
"""The paper's geometric-mean aggregate, computed CROSS-EPISODE.

Crafter's published score

    S = exp( (1/22) * sum_i ln(1 + 100 * p_i) ) - 1

where `p_i` is the SUCCESS RATE of achievement `i` across a run of episodes,
is a cross-episode aggregate: a single episode has no success rate, only a
boolean per achievement. This coworld therefore reports the per-episode
integer `scores[0]` — which is what a league round can rank — plus the raw
material this script needs (`achievementUnlocked[22]`, canonical order), and
this script does the aggregation.

IT IS NOT WHAT THE LADDER RANKS, and it needs at least ten episodes to mean
anything (docs/RULES.md says both).

    python3 tools/crafter_score.py <dir-of-results.json> [more dirs or files]

Prints one JSON object to stdout:

    {"score": 12.34, "episodes": 50, "rates": {"collect_wood": 0.98, ...}}

Python 3 standard library only: no Nim, no Docker, no dependency.
"""
import json
import math
import os
import sys

ACHIEVEMENTS = [
    "collect_wood", "place_table", "eat_cow", "collect_sapling",
    "collect_drink", "make_wood_pickaxe", "make_wood_sword", "place_plant",
    "defeat_zombie", "collect_stone", "place_stone", "eat_plant",
    "defeat_skeleton", "make_stone_pickaxe", "make_stone_sword", "wake_up",
    "place_furnace", "collect_coal", "collect_iron", "make_iron_pickaxe",
    "make_iron_sword", "collect_diamond",
]


def documents(paths):
    for path in paths:
        if os.path.isdir(path):
            for name in sorted(os.listdir(path)):
                if name.endswith(".json"):
                    yield os.path.join(path, name)
        else:
            yield path


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    hits = {name: 0 for name in ACHIEVEMENTS}
    episodes = 0
    for path in documents(argv[1:]):
        try:
            with open(path, encoding="utf-8") as handle:
                results = json.load(handle)
        except (OSError, ValueError) as error:
            print("skipping %s: %s" % (path, error), file=sys.stderr)
            continue
        ids = results.get("achievementIds") or ACHIEVEMENTS
        unlocked = results.get("achievementUnlocked")
        if not isinstance(unlocked, list) or len(unlocked) != len(ids):
            print("skipping %s: no achievementUnlocked[22]" % path,
                  file=sys.stderr)
            continue
        episodes += 1
        for name, on in zip(ids, unlocked):
            if on and name in hits:
                hits[name] += 1
    if episodes == 0:
        print(json.dumps({"score": 0.0, "episodes": 0, "rates": {}}))
        return 1
    rates = {name: hits[name] / episodes for name in ACHIEVEMENTS}
    total = sum(math.log(1.0 + 100.0 * rates[name]) for name in ACHIEVEMENTS)
    score = math.exp(total / len(ACHIEVEMENTS)) - 1.0
    report = {"score": score, "episodes": episodes, "rates": rates}
    if episodes < 10:
        report["warning"] = ("a success rate over %d episodes is noise; the "
                             "aggregate needs at least 10" % episodes)
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
