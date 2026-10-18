# Prompt diversity and candidate data

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` selects one of those five using explicit nonnegative
`promptSeed % 5`. Selection remains fixed throughout the episode and does not
consume simulation randomness. `heldout-briefing` and `heldout-reference` are
reserved for evaluation. The canonical prompt retains the original bytes;
all wordings share the original rules, action examples, and strategic hints.

The bridge and source exporter use `crafter-rules-v1` and record hashes of the
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

## Private teacher candidates

```sh
nim c -d:release --path:src -o:/tmp/crafter-export tools/export_posttrain.nim
/tmp/crafter-export /tmp/crafter-candidates 10 1 standard mixed 4
```

Run from a clean, committed checkout. The exporter records complete games in
private `trajectories.jsonl` files using the shared Coworld decision/episode
contract. These are candidates, not approved training examples. Shared review
and import tooling owns training admission and splits by `seed_family`.
Families exclude wording and variant, keeping related worlds in the same split.
Held-out wordings are rejected by this training exporter.

`execution.jsonl` joins each decision to its queued and actually executed
primitives, tick interval, interruptions, repairs, and terminal flag.
`executed_action` in the candidate stream is the normalized plan installed by
the host; it does not claim that every queued primitive ran. `manifest.json`
records the source revision, wording selection, and complete-game results.
Artifacts use mode 0600 and refuse existing output paths.

The teacher is the published scripted `forager`. No provider request, call ID,
or behavior log probability is fabricated. Compare matched seeds and actions
across wordings, then evaluate models separately. Deterministic trajectory
parity does not demonstrate improved learning or resistance to policy collapse.

## Native request evidence

Set `CRAFTER_HOST_TRACE_PATH`, `CRAFTER_ATTEMPT_TRACE_DIR`, and
`CRAFTER_SOURCE_REVISION` to capture private host decisions and actual request
attempts. Each request includes the rendered retry message, assistant prefill,
model, token limit, response, parse result, and failure. Host traces record
normalized plans and actual per-tick execution. Skipped calls create no attempts.
Do not publish these files: they include the player's strategy and private notes.

```sh
python3 tools/test_native_prompts.py /tmp/crafter /tmp/crafter-player /tmp/crafter-native
python3 tools/test_export_posttrain.py /tmp/crafter-export
```

The native workflow uses real host/player processes and a closed local inference
endpoint. It preserves manifest budgets and checks failed attempts, fallback
plans, primitive execution, results, and public replay separation. It does not
claim successful model inference. `--smoke` covers both canonical variants;
the full panel additionally covers every wording on standard.

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
