"""Complete published Crafter games and join candidates to actual primitive execution."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("standard", "longnight")

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    families: dict[str, set[str]] = {}
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run([str(binary), str(output), "10", "1", variant], cwd=ROOT, check=True)
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(manifest["runs"]) == 10
            for filename in ("trajectories.jsonl", "execution.jsonl", "manifest.json"):
                assert (output / filename).stat().st_mode & 0o777 == 0o600
            decisions = episodes = terminals = ticks = 0
            with (output / "trajectories.jsonl").open() as stream, (output / "execution.jsonl").open() as execution:
                for line in stream:
                    row = json.loads(line)
                    assert row["game"] == "crafter" and row["source_revision"] == manifest["source_revision"]
                    if row["event_type"] == "episode":
                        run = manifest["runs"][episodes]
                        assert row["status"] == "completed" and decisions == run["decisions"]
                        assert terminals == 1 and decisions > 0
                        result = row["outcome"]
                        assert result["reason"] == "complete"
                        assert result["finalTick"] == result["survivalTicks"] == ticks
                        assert result["primitivesExecuted"] == ticks
                        assert row["participant_outcomes"]["0"]["score"] == run["score"]
                        assert run["score"] == 10000 * run["achievements"] + ticks
                        assert ticks <= 1344 and decisions <= 56
                        families.setdefault(row["seed_family"], set()).add(variant)
                        decisions = terminals = ticks = 0
                        episodes += 1
                        continue
                    assert row["event_type"] == "decision" and row["visibility"] == "private"
                    assert row["decision_index"] == decisions and terminals == 0
                    applied = json.loads(next(execution))
                    assert applied["source_revision"] == row["source_revision"]
                    assert applied["episode_id"] == row["episode_id"] and applied["decision_id"] == row["decision_id"]
                    assert applied["visibility"] == "private" and applied["terminal"] == row["terminal"]
                    assert applied["start_tick"] == ticks
                    controls = applied["executed_primitives"]
                    assert applied["end_tick"] - ticks == len(controls) and 0 < len(controls) <= 24
                    queued = applied["queued_primitives"]
                    assert controls == (queued + ["noop"] * 24)[: len(controls)]
                    if len(controls) < 24:
                        assert applied["interrupted"] or applied["terminal"]
                    assert applied["dropped"] == applied["over_cap"] == 0
                    ticks = applied["end_tick"]
                    decisions += 1
                    terminals += row["terminal"]
                    (attempt,) = row["attempts"]
                    assert attempt["origin"] == "teacher" and attempt["policy"] == "scripted-forager"
                    assert attempt["request"] is None and attempt["platform_call_id"] is None
                    assert attempt["behavior_logprobs"] is None
                    assert json.loads(attempt["response"]) == attempt["parsed_action"]
                    metadata = row["observation"]["prompt_template"]
                    for message in attempt["prompt"]:
                        assert (
                            metadata[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    assert row["action_status"] == "accepted" and attempt["accepted"]
                    assert row["selected_attempt_id"] == attempt["attempt_id"]
                    assert row["executed_action"] == attempt["parsed_action"]
                assert execution.read() == ""
            assert episodes == 10 and decisions == 0
            print(variant, "10 complete private source games and primitive traces PASS", flush=True)
    assert len(families) == 10 and all(variants == set(VARIANTS) for variants in families.values())
