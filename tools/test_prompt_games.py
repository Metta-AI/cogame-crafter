"""Complete published Crafter games with matched wordings and actual plan execution."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = Path(sys.argv[1]).resolve()
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(variant, seed, wording="canonical", prompt_seed=0, repair=False):
    args = [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant, "text"]
    with subprocess.Popen(
        args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 1,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test" if wording.startswith("heldout-") else "train",
            }
        )
        trace = []
        system = None
        while observation["kind"] == "decision":
            assert observation["decision_id"] == len(trace) and observation["seat"] == 0
            view = observation["semantic_view"].copy()
            messages = observation["messages"]
            metadata = view.pop("prompt_template")
            selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            assert (metadata["bank"], metadata["variant"]) == (
                "crafter-rules-v2",
                selected,
            )
            for message in messages:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            assert "seed" not in view and "score" not in view
            assert json.loads(messages[1]["content"].split("\n")[-1]) == view
            if system is None:
                system = messages[0]["content"]
            assert messages[0]["content"] == system
            proposal = json.loads(request({"kind": "teacher"})["response"])
            if repair:
                proposal["say"] = "雪" * 180
                proposal["notes"] = "森" * 430
                proposal["actions"].insert(0, {"act": "unknown-command"})
                if trace:
                    assert view["notes"] == "森" * 400
            result = request(
                {
                    "kind": "step",
                    "decision_id": len(trace),
                    "response": json.dumps(proposal),
                }
            )
            assert result["kind"] == "accepted"
            if repair:
                assert result["action"]["say"] == "雪" * 160
                assert result["action"]["notes"] == "森" * 400
                assert all(
                    action["act"] != "unknown-command"
                    for action in result["action"]["actions"]
                )
            else:
                assert result["action"] == proposal
            trace.append((view, messages, result["action"]))
            observation = result["observation"]
            assert len(trace) <= 56
        process.stdin.close()
        assert process.wait(timeout=30) == 0
        assert observation["kind"] == "terminal" and trace
        assert set(observation["scores"]) == {"0"}
        assert 0 <= observation["scores"]["0"] <= 221344
        assert (
            abs(
                observation["utilities"]["0"]
                - (2 * observation["scores"]["0"] / 221344 - 1)
            )
            < 1e-9
        )
        return trace, observation


for variant in ("standard", "longnight"):
    for heldout in WORDINGS[5:]:
        rejected = subprocess.run(
            [
                str(BRIDGE),
                str(ROOT / "coworld_manifest_template.json"),
                variant,
                "text",
            ],
            input=json.dumps(
                {
                    "kind": "reset",
                    "players": 1,
                    "seed": "17",
                    "promptVariant": heldout,
                    "split": "train",
                }
            )
            + "\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert rejected.returncode != 0 and "evaluation-only" in rejected.stderr
    for seed in ("17",):
        canonical = None
        introductions = set()
        selected_systems = {}
        for wording, prompt_seed in [*((name, 0) for name in WORDINGS), ("mixed", 4)]:
            trace, outcome = play(variant, seed, wording, prompt_seed)
            selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            rendered = trace[0][1][0]["content"]
            assert selected_systems.setdefault(selected, rendered) == rendered
            introductions.add(rendered)
            stripped = [(view, messages[1], action) for view, messages, action in trace]
            if canonical is None:
                canonical = stripped, outcome
            else:
                assert (stripped, outcome) == canonical
        assert len(introductions) == 7
        print(variant, seed, "8 complete matched wording games PASS", flush=True)
    play(variant, "17", repair=True)
    print(variant, "complete repaired plan and private notes workflow PASS", flush=True)
