# Prompt diversity and teacher data

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` selects one of those five using explicit nonnegative
`promptSeed % 5`. Selection remains fixed throughout the episode and does not
consume simulation randomness. `heldout-briefing` and `heldout-reference` are
reserved for evaluation. The canonical prompt retains the original bytes;
Alternatives vary the introduction, planning instructions, and scoring explanation.
Observation fields, crafting rules, action examples, and strategic hints retain their meaning.

The bridge and source exporter use `crafter-rules-v2` and record hashes of the
rendered system and user messages in private provenance. Metadata stays out of
model input and public replays. Changing wording does not change world generation,
partial observation, action parsing, score, or the published turn and tick budgets.

## Full-text collection

```sh
nim c -d:release --path:src -o:/tmp/crafter-train-bridge tools/train_bridge.nim
```

Pass `[/tmp/crafter-train-bridge, /absolute/path/coworld_manifest_template.json,
standard, text]` to the shared Metta text collector with `players=1`.
Use `longnight` for the other published variant. Reset accepts `promptVariant`,
`promptSeed`, and `split`; training rejects both held-out wordings.

This path accepts complete JSON plans, including `goto`, repeated primitives,
`say`, and private `notes`. The actual game parser normalizes submissions and
returns the accepted plan. The simulator executes each primitive and preserves
its ordinary interruption behavior. The next observation describes the previous
turn's executed primitives; a queued plan can be interrupted before completion.

## Teacher exports

```sh
nim c -d:release --path:src -o:/tmp/crafter-export tools/export_posttrain.nim
/tmp/crafter-export /tmp/crafter-examples 10 1 standard mixed 0
```

Run from a clean, committed checkout. The exporter keeps the original
`train.jsonl`, `validation.jsonl`, and `manifest.json` format.
It runs complete scripted-forager games, records wording metadata, and keeps
only plans unchanged by the actual parser. Plans may still be interrupted by
damage during execution, exactly as in the game.

Mixed selection cycles the five training wordings separately within each split,
so validation does not remove a wording from training. Episode IDs include the
selected wording, distinguishing matched collections of the same scenario.
Seed families exclude wording and world variant; seed multiples of five enter
validation. Held-out wordings are rejected. Output directories are private and
must not already exist.

```sh
python3 tools/test_export_posttrain.py /tmp/crafter-export
python3 tools/test_prompt_games.py /tmp/crafter-train-bridge
```

These complete-game checks cover both published variants, plan normalization,
private notes, and wording-independent outcomes. They do not measure learning
or resistance to policy collapse.

# Numeric training

The numeric bridge runs the same simulator, baseline policies, reply parser,
and per-turn driver used in hosted games. Each decision exposes the exact
player-visible observation as `semantic_view` and a fixed 437-feature numeric
encoding. Its 33 choices are the published forager and wanderer baselines,
17 direct primitives, four four-step moves, and `goto` for each of the ten
nearest known terrain categories. Missing `goto` targets are masked. The
catalog does not enumerate every possible multi-action plan.

```sh
nim c -d:release --path:src -o:/tmp/crafter-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/crafter-train-bridge
```

With a Metta checkout containing the generic Coworld bridge, pass
`[/tmp/crafter-train-bridge, /absolute/path/coworld_manifest_template.json,
standard]` to `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` for native PufferLib. Replace `standard` with
`longnight` for the second certified variant, set `players=1`, and use a
finite timestep limit. The bridge embeds no hidden seed or score in its
observation. Its full teacher and random games complete for both variants.
Metta RL completed 512 steps per variant and evaluation; mean returns were
-0.952 for standard and -0.906 for longnight. Native PufferLib completed
4,096 CUDA steps per variant, then evaluated four episodes on each of seeds
101 and 102. Standard mean scores were 115,432.5 and 100,419.5; longnight
mean scores were 165.5 and 290.75. These pilots prove the optimizer,
checkpoint, and evaluator paths; the short runs do not establish policy
quality.

Episode IDs include the requested selection, resolved wording, and prompt seed.
Matched exports remain distinct while scenario seed families stay unchanged.
