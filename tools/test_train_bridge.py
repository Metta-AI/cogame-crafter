"""Run full certified Crafter variants through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


BINARY = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"


def play(variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(BINARY), str(MANIFEST), variant],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        cwd="/tmp",
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(13)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"crafter-{variant}-{teacher}", "players": 1})
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            assert observation["game"] == "crafter" and observation["seat"] == 0
            assert observation["decision_id"] == decisions
            view = observation["semantic_view"]
            assert "seed" not in view and "score" not in view
            assert json.loads(observation["messages"][1]["content"].split("\n")[-1]) == view
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == decisions
            widths.add(len(encoding["values"]))
            assert len(encoding["actions"]) == 33
            if teacher:
                choice = json.loads(request({"kind": "teacher"})["response"])
            else:
                choice = rng.choice([action for action in encoding["actions"] if action is not None])
            result = request({"kind": "step", "decision_id": decisions,
                              "response": json.dumps(choice)})
            assert result["kind"] == "accepted" and result["action"] == choice
            observation = result["observation"]
            decisions += 1
            assert decisions <= 56
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0"}
        assert set(observation["utilities"]) == {"0"}
        expected = 2 * observation["scores"]["0"] / (10_000 * 22 + 1344) - 1
        assert abs(observation["utilities"]["0"] - expected) < 1e-9
        assert widths == {437} and decisions > 0
        print(variant, "teacher" if teacher else "random", decisions, observation["scores"])
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    for name in ("standard", "longnight"):
        for use_teacher in (True, False):
            play(name, use_teacher)
