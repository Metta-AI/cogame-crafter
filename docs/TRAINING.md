# Metta post-training data

The maintained native simulator and its published `forager` policy can
produce supervised fine-tuning examples without a model provider:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/crafter-posttrain 10
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/crafter-longnight-posttrain 10 1 longnight
```

The exporter covers both certified variants. It runs complete seeded games,
records the hosted system prompt and full player-visible observation at each
decision, and validates the teacher's action through the game's reply parser.
Train and validation split by episode seed. `manifest.json` records the source
revision, teacher, variant, scores, achievement counts, and row counts. The
exporter refuses to overwrite an existing output directory.

Train the shared Metta post-training pipeline on either output directory:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/crafter-posttrain \
  --output /tmp/crafter-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

This dataset distills a scripted teacher. It does not claim that a model
selected the actions or that league performance will improve. Seeds and
unseen map cells stay out of each prompt.

The local 10-game standard proof exported 239 train and 60 validation rows.
The long-night proof exported 122 train and 38 validation rows. All 459 rows
fit a 4096-token smoke model. One CPU optimizer update reduced validation
loss from 1.7651 to 1.7587 on standard and from 1.7569 to 1.7507 on long night.

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
