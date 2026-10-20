"""Check complete seeded mixed-wording exports for both published Crafter worlds."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("standard", "longnight")

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run(
                [str(binary), str(output), "10", "1", variant, "mixed", "0"],
                cwd=ROOT,
                check=True,
            )
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(manifest["runs"]) == 10
            assert all(
                run["decisions"] > 0
                and 0 <= run["achievements"] <= 22
                and 10000 * run["achievements"]
                <= run["score"]
                <= 10000 * run["achievements"] + 1344
                for run in manifest["runs"]
            )
            families, counts = {}, {}
            for split in ("train", "validation"):
                rows = [
                    json.loads(line)
                    for line in (output / f"{split}.jsonl").read_text().splitlines()
                ]
                assert len(rows) == manifest[split + "_examples"] > 0
                families[split] = {row["seed"] for row in rows}
                if split == "train":
                    assert {row["prompt_template"]["variant"] for row in rows} == {
                        "canonical",
                        "plain",
                        "numbered",
                        "questions",
                        "reordered",
                    }
                for row in rows:
                    assert row["game"] == "crafter"
                    assert [message["role"] for message in row["prompt"]] == [
                        "system",
                        "user",
                    ]
                    plan = json.loads(row["completion"][0]["content"])
                    assert 0 < len(plan["actions"]) <= 12
                    assert len(plan["say"]) <= 160 and len(plan["notes"]) <= 400
                    assert row["prompt_template"]["variant"] not in (
                        "heldout-briefing",
                        "heldout-reference",
                    )
                    counts[row["seed"]] = counts.get(row["seed"], 0) + 1
            assert families["train"].isdisjoint(families["validation"])
            assert all(
                counts[f"crafter-{run['seed']}"] == run["decisions"]
                for run in manifest["runs"]
            )
            print(variant, "10 complete mixed exports PASS", flush=True)
