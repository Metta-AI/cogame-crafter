## Manifest — design note §Tests items 37 and 38.

import std/[json, os, osproc, sequtils, sets, strutils, unittest]
import crafter/[sim, driver, directives, baselines]
import helpers

proc gameConfigOf(node: JsonNode): GameConfig =
  ## The manifest's `game_config` as a real `GameConfig`, exactly the way the
  ## runner hands it over — tokens injected, everything else verbatim.
  var payload = node.copy()
  payload["tokens"] = %*["token-0"]
  result = defaultGameConfig()
  result.update($payload)

suite "the manifest pins":
  let m = manifest()

  test "num_agents is 1 in both variants AND the cert fixture, inside game_config":
    check m["variants"].len == 2
    for variant in m["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 1
      ## Never at the variant's TOP level: `CoworldVariant` is
      ## additionalProperties:false and rejects it (goofspiel-oshi-zumo 0.1.0).
      check not variant.hasKey("num_agents")
      check variant.hasKey("id")
      check variant.hasKey("name")
      check variant["description"].getStr().len > 40
    check m["certification"]["game_config"]["num_agents"].getInt() == 1

  test "no literal tokens in any game_config":
    ## matriculate rejects "game_config must not include runner-managed
    ## tokens" (knights-archers 0.1.0), while config_schema keeps REQUIRING
    ## them because the runner injects them.
    for variant in m["variants"]:
      check not variant["game_config"].hasKey("tokens")
    check not m["certification"]["game_config"].hasKey("tokens")
    check "tokens" in m["game"]["config_schema"]["required"].getElems().mapIt(
      it.getStr()).toHashSet()

  test "exactly one declared player, and it is seated in the fixture":
    ## Every declared player must occupy a certification slot (raid 0.1.2).
    check m["player"].len == 1
    let declared = m["player"][0]["id"].getStr()
    check declared == "forager"
    check m["certification"]["players"].len == 1
    check m["certification"]["players"][0]["player_id"].getStr() == declared
    check m["certification"]["game_config"]["players"].len == 1
    ## `limits.cpu` must be at least "1" (pistonball 0.1.1).
    check m["player"][0]["resources"]["limits"]["cpu"].getStr() == "1"
    check m["player"][0]["image"].getStr() == "{{CRAFTER_IMAGE}}"
    check m["player"][0]["run"][0].getStr() == "/bin/crafter-player"
    check m["player"][0]["description"].getStr().len > 20

  test "every array in config_schema carries minItems and maxItems":
    ## The tandem 0.1.0 scar.
    for name, property in m["game"]["config_schema"]["properties"]:
      if property{"type"}.getStr() != "array":
        continue
      check property.hasKey("minItems")
      check property.hasKey("maxItems")

  test "episode_timeout_minutes is top level and the tags are not under game":
    check m.hasKey("episode_timeout_minutes")
    check not m["game"].hasKey("episode_timeout_minutes")
    check m["tags"].len >= 3
    check not m["game"].hasKey("tags")          ## pistonball 0.1.0
    check m["game"]["description"].getStr().len > 40
    check m.hasKey("$schema")
    check not m.hasKey("version")               ## coworld 0.1.42
    check not m["game"].hasKey("display_name")
    check m["game"]["owner"].getStr().len > 0

  test "protocols and docs are {type,value} objects, never bare strings":
    ## The garble v0.1.0 scar.
    for key in ["player", "global"]:
      let node = m["game"]["protocols"][key]
      check node.kind == JObject
      check node.hasKey("type")
      check node["value"].getStr().startsWith("https://")
    check m["game"]["docs"]["readme"]["value"].getStr().endsWith("README.md")
    var pages: HashSet[string]
    for page in m["game"]["docs"]["pages"]:
      pages.incl(page["id"].getStr())
      check page["content"]["value"].getStr().startsWith("https://")
      check page.hasKey("title")
    check pages == ["rules.md", "actions.md", "achievements.md",
                    "porting.md"].toHashSet()
    ## Every page the manifest points at is committed.
    for page in m["game"]["docs"]["pages"]:
      let url = page["content"]["value"].getStr()
      let path = url.split("/blob/main/")[^1]
      check fileExists(repoRoot() / path)

  test "the replay viewer is the STATIC bundle, under game, never a pod":
    check m["game"]["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    check not m.hasKey("replay_viewer")
    check m["game"]["runnable"]["type"].getStr() == "game"
    check m["game"]["runnable"]["run"][0].getStr() == "/bin/crafter"

  test "the runnable and every declared player resolve to this repo":
    ## `source-resolves` is a certification prerequisite and it reads
    ## `runnable.source_url`; the starter's own manifest carries it on the game
    ## runnable as well as on each player, and a 404 there fails the upload
    ## after a fully green certify.
    let runnable = m["game"]["runnable"]
    check runnable["source_url"].getStr() ==
      "https://github.com/Metta-AI/cogame-crafter/tree/main"
    ## The image lives under `runnable`, never on `game` itself.
    check not m["game"].hasKey("image")
    for player in m["player"]:
      check player["type"].getStr() == "player"
      check player["source_url"].getStr().startsWith(
        "https://github.com/Metta-AI/cogame-crafter")

  test "game.name equals the slug and the secret namespace":
    ## The commons-family 2026-08-24 scar: an underscore in `game.name` and
    ## the upload is rejected after a fully green certify.
    let name = m["game"]["name"].getStr()
    check name == "crafter"
    check m["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & name & "/anthropic_api_key"
    ## The compose service name is where the image placeholder comes from
    ## (lantern 0.1.0).
    let compose = readRepo("compose.yaml")
    check compose.contains("  " & name & ":")
    check m["game"]["runnable"]["image"].getStr() == "{{CRAFTER_IMAGE}}"

  test "the deadlines and the caps satisfy every validator":
    for config in [m["variants"][0]["game_config"],
                   m["variants"][1]["game_config"],
                   m["certification"]["game_config"]]:
      let resolved = gameConfigOf(config)
      check resolved.wallClockBudgetSeconds <= 660
      check resolved.attempt1Ms mod 1000 == 0
      check resolved.retryMs mod 1000 == 0
      check resolved.attempt1Ms + resolved.retryMs <= resolved.turnBudgetMs
      check resolved.maxTicks == resolved.maxTurns * resolved.turnTicks
      check resolved.dayFraction < resolved.dayLength
      check resolved.numAgents == 1

  test "the results_schema achievement arrays are pinned at 22":
    let props = m["game"]["results_schema"]["properties"]
    for key in ["achievementIds", "achievementUnlocked", "achievementTick"]:
      check props[key]["minItems"].getInt() == AchievementCount
      check props[key]["maxItems"].getInt() == AchievementCount
    check props["toolsOwned"]["minItems"].getInt() == 0
    check props["toolsOwned"]["maxItems"].getInt() == 6
    check m["game"]["results_schema"]["additionalProperties"].getBool() == false
    var reasons: HashSet[string]
    for value in props["reason"]["enum"]:
      reasons.incl(value.getStr())
    check reasons == ["complete", "deadline", "fault"].toHashSet()
    var rules: HashSet[string]
    for value in props["endRule"]["enum"]:
      rules.incl(value.getStr())
    check rules == ["death", "allUnlocked", "turnCap", "tickCap", "wallClock",
                    "fault"].toHashSet()
    var causes: HashSet[string]
    for value in props["deathCause"]["enum"]:
      causes.incl(value.getStr())
    check causes == ["zombie", "skeleton", "arrow", "lava", "starvation",
                     "thirst", "exhaustion", "none"].toHashSet()

  test "EVERY variant's game_config constructs, generates and plays":
    ## The collab-cooking 0.1.1 scar: test every variant, not just the
    ## fixture. A config-scaled mint that only the smaller fixture survives is
    ## a league of `game_unhealthy` episodes with a green cert.
    for variant in m["variants"]:
      let config = gameConfigOf(variant["game_config"])
      config.validate()
      ## It generates a world that passes the generation invariants...
      let world = generate(config.seed + 11, config.mountainThreshold)
      var counts = [0, 0, 0]
      for slot in 0 ..< WorldCells:
        case world.cells[slot]
        of tCoal: inc counts[0]
        of tIron: inc counts[1]
        of tDiamond: inc counts[2]
        else: discard
      check counts[0] >= 5
      check counts[1] >= 3
      check counts[2] >= 1
      ## ...and it produces the 56-turn schedule this note claims.
      check config.maxTurns == 56
      check config.turnTicks == 24
      var play = config
      play.seed = 5
      play.lobbyJoinTimeoutTicks = 4
      let sim = playScripted(play, blForager)
      check sim.phase == GameOver
      check sim.endReason == erComplete
      check sim.turnsPlayed <= config.maxTurns
      check sim.survivalTicks() <= config.maxTicks

  test "the shipped policy set is two prompts and two scripted fillers":
    let policies = parseJson(readRepo("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/crafter-player"
      check policy["name"].getStr().startsWith("crafter-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 400
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check parseBaseline(policy["env"]["PLAYER_SCRIPTED"].getStr()) in
          [blForager, blWanderer]
    ## A scripted policy seated as a CHAMPION is a failure state: both
    ## champions run PLAYER_PROMPT, and champion #2 is owned by daveey-1.
    check prompts == 2
    check scripted == 2
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"

  test "the manifest loads: the placeholders resolve and the shape validates":
    ## Item 38. `coworld` is not installed on the `test` runner and `ci.yml`
    ## never installs it, so a check that only runs UNDER THE CLI runs
    ## nowhere — which left the shipped `game.runnable` asserted by nothing
    ## that executes. So the substantive half below runs EVERYWHERE: it
    ## substitutes the image placeholder exactly the way `coworld build` does,
    ## re-parses the result, and asserts the structure
    ## `validate_upload_manifest` requires. The CLI load still runs wherever
    ## the CLI exists, and `coworld-release.yml`'s own build step is the hard
    ## gate.
    let raw = readRepo("coworld_manifest_template.json")
    ## EVERY placeholder in the template is one `coworld build` substitutes.
    ## An unsubstituted `{{...}}` reaches the platform verbatim and the game
    ## is unschedulable (lantern 0.1.0).
    var placeholders: HashSet[string]
    var index = 0
    while true:
      let start = raw.find("{{", index)
      if start < 0:
        break
      let stop = raw.find("}}", start)
      check stop > start
      placeholders.incl(raw[start .. stop + 1])
      index = stop + 2
    check placeholders == ["{{CRAFTER_IMAGE}}"].toHashSet()

    let resolved = parseJson(raw.replace("{{CRAFTER_IMAGE}}",
                                         "coworld-crafter:ci"))
    check resolved["game"]["runnable"]["image"].getStr() == "coworld-crafter:ci"
    for player in resolved["player"]:
      check player["image"].getStr() == "coworld-crafter:ci"
    for key in ["$schema", "tags", "episode_timeout_minutes", "game", "player",
                "variants", "certification"]:
      check resolved.hasKey(key)
    for key in ["name", "owner", "description", "runnable", "replay_viewer",
                "protocols", "docs", "config_schema", "results_schema"]:
      check resolved["game"].hasKey(key)
    for key in ["type", "image", "run", "source_url", "env"]:
      check resolved["game"]["runnable"].hasKey(key)
    for player in resolved["player"]:
      for key in ["id", "type", "name", "description", "image", "run",
                  "source_url", "resources"]:
        check player.hasKey(key)
    for variant in resolved["variants"]:
      check toSeq(variant.keys) == @["id", "name", "description",
                                     "game_config"]

    let probe = execCmdEx("python3 -c 'import coworld' 2>/dev/null")
    if probe.exitCode == 0:
      let run = execCmdEx("python3 -c " & quoteShell(
        "from coworld.manifest import validate_upload_manifest;" &
        "import json,sys;" &
        "validate_upload_manifest(json.load(open(sys.argv[1])))") & " " &
        quoteShell(repoRoot() / "coworld_manifest_template.json"))
      check run.exitCode == 0
    else:
      echo "        (no `coworld` CLI here; the structural half above is what ",
        "ran)"
