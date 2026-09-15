#!/usr/bin/env python3
"""Prompt-cache probe: does the app's system prompt actually cache?

Sends a scripted multi-turn conversation built from the *real* prompt that
`PromptBuilder` produces, and reports per-turn prompt/cached tokens so you can
see the hit rate rather than infer it.

Why a control arm
-----------------
A hit rate of zero is ambiguous: either caching is broken, or the probe is.
So every run does two arms:

  * ``stable``  — the app's layout: fixed text first, volatile text last.
  * ``control`` — a per-turn nonce injected at the *front* of the system
                  prompt. This reproduces the old bug (live sensor readings sat
                  above the tool policy) and must show zero hits.

If ``stable`` hits and ``control`` misses, the probe works and the prompt is
cacheable. If both miss, caching is not engaging at all. If both hit, the probe
is not measuring what it claims to.

Usage
-----
    python3 eval/cache_probe.py                          # default model
    python3 eval/cache_probe.py --model meta/muse-spark-1.3-contributor
    python3 eval/cache_probe.py --cache-mode explicit    # Anthropic-style
    python3 eval/cache_probe.py --turns 6 --raw-usage    # dump provider usage

Key resolution matches run.py: ``OBDIAG_EVAL_KEY`` or ``.eval/openrouter-key``.

Measured results (2026-09-14)
-----------------------------
``meta/muse-spark-1.3-contributor`` — $0.10/M in, $0.002/M cache read, no cache-write
charge. Two runs, 6 turns each:

====  =====================  ========  ============
run   arm                    hit rate  input saved
====  =====================  ========  ============
1     stable (app layout)    50%       48.6%
1     control (old layout)     2%        2.1%
2     stable (app layout)    54%       53.0%
2     control (old layout)     6%        5.7%
====  =====================  ========  ============

So the reordering turns a ~0% hit rate into ~50%, halving input cost. Two
caveats worth carrying forward:

  * **~50%, not ~95%.** The provider caches in ~128-token blocks and is
    best-effort: some turns miss entirely on an unchanged prefix, and even a
    byte-identical repeat alternated 0%/75%/0%/75%. Do not plan around a
    theoretical hit rate.
  * **No write charge on this route**, so caching is free upside. That is not
    true of Anthropic, which bills 1.25x (5m) or 2x (1h) to write — there a miss
    costs more than not caching at all.

Two probe bugs found while measuring, both fixed and both of which had produced
false passes: a previous run's identical content warmed the cache so turn 1 was
never cold, and byte-identical tool-result filler let the control arm match
blocks from the stable arm.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Optional

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

import harness  # noqa: E402  (sets SSL_CERT_FILE from certifi on import)

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

DEFAULT_MODEL = "meta/muse-spark-1.3-contributor"

# Roughly what a get_live_data / get_fault_codes result looks like in size.
TOOL_RESULT_TOKENS = 900
FILLER = ("- Coolant temperature: 92 °C [normal] | Engine RPM: 780 [normal] | "
          "Short term fuel trim bank 1: 3.1 % [normal] | Battery voltage: 14.2 V [normal]. ")


def resolve_key(explicit: Optional[str]) -> Optional[str]:
    if explicit:
        return explicit.strip()
    key = os.environ.get("OBDIAG_EVAL_KEY", "").strip()
    if key:
        return key
    for candidate in (ROOT / ".eval" / "openrouter-key", HERE / ".key"):
        if candidate.exists():
            value = candidate.read_text().strip()
            if value:
                return value
    return None


# ---------------------------------------------------------------------------
# Token-usage extraction
# ---------------------------------------------------------------------------

def _first_int(sources: list[dict[str, Any]], keys: tuple[str, ...]) -> int:
    for source in sources:
        for key in keys:
            value = source.get(key)
            if isinstance(value, (int, float)) and value > 0:
                return int(value)
    return 0


def cached_tokens(usage: dict[str, Any]) -> int:
    """Cache *reads*. Providers disagree on the field name."""
    details = usage.get("prompt_tokens_details") or {}
    return _first_int(
        [details, usage],
        ("cached_tokens", "cache_read_input_tokens", "prompt_cache_hit_tokens", "cached"),
    )


def written_tokens(usage: dict[str, Any]) -> int:
    """Cache *writes*, where the provider charges for populating the cache."""
    details = usage.get("prompt_tokens_details") or {}
    return _first_int(
        [details, usage],
        ("cache_write_tokens", "cache_creation_input_tokens", "prompt_cache_miss_tokens"),
    )


# ---------------------------------------------------------------------------
# Prompt construction — mirrors PromptBuilder's stable/volatile split
# ---------------------------------------------------------------------------

def prompt_blocks(run_id: str) -> tuple[str, str]:
    """The app's stable/volatile split, tagged with a per-run cache namespace.

    The run id is prepended to the *stable* block, so it is part of the
    cacheable prefix but identical for every turn within a run. That gives a
    genuinely cold first turn while still letting turns 2+ hit — without it, a
    previous run's identical scripted content warms the cache and the control
    arm can collide with an earlier control run, which is exactly how the first
    version of this probe produced a false 99% on a control turn.
    """
    scenario = {
        "vehicle": {
            "year": 2018, "make": "Honda", "model": "Civic", "trim": "EX-L",
            "vin": "1HGCM82633A004352", "engine": "1.5L 4-cyl turbo",
            "fuelType": "Gasoline", "bodyClass": "Sedan", "driveType": "FWD",
        },
        "obd": {"connected": True, "codes": [{"code": "P0420", "status": "stored"}]},
    }
    readings = {"coolantTemperature": harness.Reading(92.0), "engineRPM": harness.Reading(780.0)}
    state = harness.OBDState(readings=readings)
    stable = "\n\n".join(harness._stable_prompt_sections(True, "imperial", scenario))
    volatile = "\n\n".join(harness._volatile_prompt_sections(scenario, state, "imperial"))
    return f"[cache-probe run {run_id}]\n\n" + stable, volatile


def system_message(stable: str, volatile: str, mode: str, nonce: Optional[int]) -> dict[str, Any]:
    """Build the system message for one turn.

    ``nonce`` reproduces the old failure: a value that changes every turn placed
    ahead of everything else, which invalidates the entire prefix.
    """
    prefix = f"[probe nonce {nonce}] " if nonce is not None else ""

    if mode == "explicit":
        # Anthropic requires the marker; the volatile block stays after it.
        blocks: list[dict[str, Any]] = [
            {"type": "text", "text": prefix + stable, "cache_control": {"type": "ephemeral"}},
        ]
        if volatile:
            blocks.append({"type": "text", "text": volatile})
        return {"role": "system", "content": blocks}

    text = prefix + stable if not volatile else f"{prefix}{stable}\n\n{volatile}"
    return {"role": "system", "content": text}


def filler_tool_result(salt: str = "") -> str:
    """Synthetic tool output, salted so no two arms share block hashes.

    Providers cache in fixed-size blocks keyed by content hash. If both arms
    emit byte-identical tool results, the control arm matches blocks from the
    stable arm even though its prefix diverges at position 0 — which showed up
    as spurious 64% hits on a control turn that cannot legitimately hit.
    """
    repeats = max(1, TOOL_RESULT_TOKENS * 4 // len(FILLER))
    tag = f"[probe {salt}] " if salt else ""
    return f"get_live_data result:\n{tag}" + FILLER * repeats


def scripted_requests(stable: str, volatile: str, *, turns: int, mode: str,
                      nonce: bool, tools: list[dict[str, Any]], salt: str = "") -> list[dict[str, Any]]:
    """One request per turn, each carrying the whole conversation so far."""
    tool_result = filler_tool_result(salt)
    conversation: list[dict[str, Any]] = []
    requests: list[dict[str, Any]] = []

    for turn in range(1, turns + 1):
        conversation.append({
            "role": "user",
            "content": f"Turn {turn}: the check engine light is on. What should I check next?",
        })

        messages = [system_message(stable, volatile, mode, turn if nonce else None)]
        messages.extend(conversation)

        if mode == "explicit":
            # Mirror the app: a breakpoint at the end of the transcript too, so
            # the growing conversation caches rather than only the system block.
            for index in range(len(messages) - 1, -1, -1):
                if messages[index]["role"] in ("user", "assistant", "tool") and isinstance(
                    messages[index].get("content"), str
                ):
                    messages[index] = {
                        **messages[index],
                        "content": [{
                            "type": "text",
                            "text": messages[index]["content"],
                            "cache_control": {"type": "ephemeral"},
                        }],
                    }
                    break

        payload: dict[str, Any] = {
            "model": None,  # filled by caller
            "messages": messages,
            "max_tokens": 16,          # response length is irrelevant to caching
            "usage": {"include": True},
        }
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        requests.append(payload)

        # Grow the transcript the way a tool-using turn would.
        conversation.append({
            "role": "assistant",
            "content": None,
            "tool_calls": [{
                "id": f"call_{turn}",
                "type": "function",
                "function": {"name": "get_live_data", "arguments": "{}"},
            }],
        })
        conversation.append({
            "role": "tool",
            "tool_call_id": f"call_{turn}",
            "name": "get_live_data",
            "content": tool_result,
        })

    return requests


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

def post(key: str, payload: dict[str, Any], timeout: int = 180) -> dict[str, Any]:
    request = urllib.request.Request(
        OPENROUTER_URL,
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://obdiag.app",
            "X-Title": "OBDiag Cache Probe",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"HTTP {err.code}: {err.read().decode()[:500]}") from err
    except urllib.error.URLError as err:
        raise RuntimeError(f"Network error: {err.reason}") from err


def run_arm(key: str, model: str, *, label: str, turns: int, mode: str, nonce: bool,
            tools: list[dict[str, Any]], raw_usage: bool, run_id: str) -> dict[str, Any]:
    stable, volatile = prompt_blocks(run_id)
    requests = scripted_requests(stable, volatile, turns=turns, mode=mode,
                                 nonce=nonce, tools=tools, salt=f"{label}-{run_id}")

    print(f"\n=== {label} ===")
    print(f"{'turn':>4} {'prompt':>8} {'cached':>8} {'written':>8} {'hit':>7} {'cost$':>9}")
    print("-" * 50)

    rows = []
    for index, payload in enumerate(requests, start=1):
        payload["model"] = model
        try:
            response = post(key, payload)
        except RuntimeError as err:
            print(f"  turn {index}: {err}")
            break

        usage = response.get("usage") or {}
        if raw_usage and index == 1:
            print("  raw usage:", json.dumps(usage, sort_keys=True))
            detail = usage.get("prompt_tokens_details")
            if detail is not None:
                print("  prompt_tokens_details:", json.dumps(detail, sort_keys=True))

        prompt = int(usage.get("prompt_tokens", 0) or 0)
        cached = cached_tokens(usage)
        written = written_tokens(usage)
        cost = float(usage.get("cost", 0.0) or 0.0)
        hit = (cached / prompt) if prompt else 0.0

        rows.append({"prompt": prompt, "cached": cached, "written": written,
                     "cost": cost, "hit": hit})
        print(f"{index:>4} {prompt:>8,} {cached:>8,} {written:>8,} {hit:>6.0%} {cost:>9.5f}")

    total_prompt = sum(r["prompt"] for r in rows)
    total_cached = sum(r["cached"] for r in rows)
    total_cost = sum(r["cost"] for r in rows)
    # Tokens that could have been cached but weren't, excluding turn 1 which
    # can never hit (nothing is cached yet).
    eligible = sum(r["prompt"] for r in rows[1:])
    hits = sum(r["cached"] for r in rows[1:])
    steady_state = (hits / eligible) if eligible else 0.0

    print(f"\n  total prompt tokens : {total_prompt:,}")
    print(f"  cache-read tokens   : {total_cached:,}")
    # Steady state excludes the unavoidable cold first turn, which can never hit.
    print(f"  steady-state hit rate (turn 2+) : {steady_state:.0%}")
    print(f"  total cost          : ${total_cost:.5f}")

    return {"rows": rows, "total_cost": total_cost, "steady_state": steady_state,
            "total_prompt": total_prompt, "total_cached": total_cached}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        help=f"OpenRouter model id (default: {DEFAULT_MODEL})")
    parser.add_argument("--turns", type=int, default=5, help="turns per arm (default: 5)")
    parser.add_argument("--cache-mode", choices=("implicit", "explicit"), default="implicit",
                        help="implicit = automatic caching; explicit = Anthropic cache_control")
    parser.add_argument("--key", help="OpenRouter key (else OBDIAG_EVAL_KEY or .eval/openrouter-key)")
    parser.add_argument("--no-tools", action="store_true",
                        help="omit tool definitions (isolates the system block)")
    parser.add_argument("--arm", choices=("both", "stable", "control"), default="both")
    parser.add_argument("--raw-usage", action="store_true",
                        help="dump the provider's usage object on turn 1")
    parser.add_argument("--run-id", default=None,
                        help="cache namespace tag (default: random per run). Pass a "
                             "fixed value to force cache reuse across runs on purpose.")
    args = parser.parse_args()

    run_id = args.run_id or uuid.uuid4().hex[:8]

    key = resolve_key(args.key)
    if not key:
        print("No OpenRouter key. Set OBDIAG_EVAL_KEY or write .eval/openrouter-key\n"
              "  mkdir -p .eval && printf '%s' \"$OPENROUTER_KEY\" > .eval/openrouter-key\n"
              "(both are gitignored)")
        return 2

    tools = [] if args.no_tools else harness.tool_definitions("client")
    print(f"model      : {args.model}")
    print(f"cache mode : {args.cache_mode}")
    print(f"turns      : {args.turns}")
    print(f"run id     : {run_id}  (fresh cache namespace)")
    print(f"tools      : {len(tools)} definitions")

    results: dict[str, Any] = {}
    if args.arm in ("both", "stable"):
        results["stable"] = run_arm(key, args.model, label="stable layout (app's real prompt)",
                                    turns=args.turns, mode=args.cache_mode, nonce=False,
                                    tools=tools, raw_usage=args.raw_usage, run_id=run_id)
    if args.arm in ("both", "control"):
        results["control"] = run_arm(key, args.model, label="control (per-turn nonce at the front)",
                                     turns=args.turns, mode=args.cache_mode, nonce=True,
                                     tools=tools, raw_usage=False, run_id=run_id)

    print("\n=== verdict ===")
    if "stable" in results and "control" in results:
        s = results["stable"]["steady_state"]
        c = results["control"]["steady_state"]
        if c > 0.10:
            print("  INCONCLUSIVE: the control arm also hit, so this probe is not "
                  "isolating prefix stability.")
        elif s > 0.30:
            print(f"  PASS: stable hit rate {s:.0%} vs control {c:.0%}. The prompt is "
                  "cacheable and the probe detects a broken prefix.")
        elif s > 0:
            print(f"  PARTIAL: stable hit rate only {s:.0%} (control {c:.0%}). "
                  "Something in the prefix is still varying between turns.")
        else:
            print(f"  FAIL: no hits on the stable layout (control {c:.0%}). Caching "
                  "is not engaging — check the minimum cacheable size and that the "
                  "model actually offers prompt caching.")
    elif "stable" in results:
        print(f"  stable hit rate: {results['stable']['steady_state']:.0%} "
              "(no control arm run, so a zero is unproven)")
    else:
        print(f"  control hit rate: {results['control']['steady_state']:.0%} "
              "(expected 0%; non-zero means the prefix is not what we think)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
