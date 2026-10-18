"""Published Crafter episodes with real players and a closed inference endpoint."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(name, "canonical") for name in variants]
    cases += [
        ("standard", wording)
        for wording in ("plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference", "mixed")
    ]
    if args.smoke:
        cases = [("standard", "canonical"), ("longnight", "canonical")]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        config.update(
            seed=7,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(seats)],
            players=[{"name": f"policy-{seat}"} for seat in range(seats)],
        )
        (work / "config.json").write_text(json.dumps(config))
        port, closed_port = free_port(), free_port()
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
            CRAFTER_HOST_TRACE_PATH=str(work / "host.jsonl"),
            CRAFTER_ATTEMPT_TRACE_DIR=str(work / "attempts"),
            CRAFTER_SOURCE_REVISION="uncommitted-crafter-validation",
        )
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen([str(args.game)], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(seats):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Climb the achievement tree while keeping vitals safe.",
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen([str(args.player)], cwd=root, env=player_env, stdout=log, stderr=subprocess.STDOUT)
                )
            assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            assert results["reason"] == "complete", results
            assert results["scores"][0] == 10000 * results["achievementsUnlocked"] + results["survivalTicks"]
            assert results["survivalTicks"] <= 1344 and results["turnsPlayed"] <= 56
            assert results["deadSeats"] == [False] and results["policyKinds"] == ["llm"]
            with (work / "host.jsonl").open() as stream:
                records = [json.loads(line) for line in stream]
            assert records[0]["event_type"] == "host_started"
            assert records[-1]["event_type"] == "host_finished" and records[-1]["results"] == results
            decisions = [row for row in records if row["event_type"] == "host_decision"]
            ticks = [row for row in records if row["event_type"] == "host_tick"]
            assert len(decisions) == results["turnsPlayed"] == results["fallbackTurns"]
            assert len(ticks) == results["survivalTicks"] == results["primitivesExecuted"]
            assert results["llmTurns"] == 0
            starts, finishes = {}, {}
            for path in (work / "attempts").glob("*.jsonl"):
                assert path.stat().st_mode & 0o777 == 0o600
                start, finish = [json.loads(line) for line in path.read_text().splitlines()]
                assert start["attempt_id"] == finish["attempt_id"]
                starts[start["attempt_id"]] = start
                finishes[finish["attempt_id"]] = finish
            assert starts and set(starts) == set(finishes)
            assert {identity for row in decisions for identity in row["attempt_ids"]} == set(finishes)
            for row in decisions:
                assert row["source"] == "fallback" and row["selected_attempt_id"] is None
                assert len(row["attempt_ids"]) in (0, 2)
                assert row["dropped"] == row["over_cap"] == 0
                metadata = row["prompt_template"]
                assert metadata["variant"] == ("reordered" if wording == "mixed" else wording)
                for message in row["prompt"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                for identity in row["attempt_ids"]:
                    start, finish = starts[identity], finishes[identity]
                    assert finish["failure"] and not finish["selected"]
                    assert finish["parsed_action"] is None and finish["normalized_action"] is None
                    assert finish["platform_call_id"] is None and finish["behavior_logprobs"] is None
                    system, user, prefill = (message["content"] for message in start["prompt"])
                    assert system == row["prompt"][0]["content"]
                    assert user.startswith(row["prompt"][1]["content"])
                    assert "PRIVATE-STRATEGY-0" in user and prefill == "{"
                    body = start["request"]["body"]
                    assert body["system"] == system and body["messages"] == start["prompt"][1:]
                    assert start["request"]["model"] == body["model"]
                    for role, text in (("system", system), ("user", user)):
                        assert (
                            start["prompt_template"][f"{role}_sha256"].lower()
                            == hashlib.sha256(text.encode()).hexdigest()
                        )
                turn_ticks = [tick for tick in ticks if tick["turn"] == row["turn"]]
                assert turn_ticks and len(turn_ticks) <= 24
                queued = row["queued_primitives"] + ["noop"] * 24
                for index, tick in enumerate(turn_ticks, start=1):
                    assert tick["tick"] == row["tick"] + index
                    assert tick["executed_primitives"] == queued[:index]
                if len(turn_ticks) < 24:
                    assert turn_ticks[-1]["interrupted"] or turn_ticks[-1]["terminal"]
            summary = json.loads(
                subprocess.check_output(
                    ["python3", "tools/replay_summary.py", str(work / "episode.replay")], cwd=root, text=True
                )
            )
            assert summary["results"] == results
            assert len(summary["plans"]) == len(decisions)
            for plan, row in zip(summary["plans"], decisions, strict=True):
                assert plan["turn"] == row["turn"] and plan["source"] == "fallback"
                assert plan["executed"] == row["queued_primitives"]
                assert plan["verbs"] == [action["act"] for action in row["executed_action"]["actions"]]
            public = (work / "episode.replay").read_bytes()
            assert b"PRIVATE-STRATEGY-" not in public and b"prompt_template" not in public
            assert (work / "host.jsonl").stat().st_mode & 0o777 == 0o600
            print(
                work.name,
                len(ticks),
                "actual ticks;",
                len(starts),
                "actual attempts;",
                len(decisions),
                "fallback plans; one real player PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
