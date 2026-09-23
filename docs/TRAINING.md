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
