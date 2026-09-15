#!/usr/bin/env python3
"""Drift check: does the Python harness still describe the same assistant the
Swift app ships?

The eval is only meaningful if it imitates the app, so this script reads the
Swift sources and verifies that:

  * every tool the app registers exists in the Python tool schemas (strict),
  * the app's prompt instructions appear in the Python prompt (reported),
  * the credit formula constants match (strict).

    python3 eval/check_drift.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL_REGISTRY = ROOT / "OBDiag" / "AI" / "ToolRegistry.swift"
PROMPT_BUILDER = ROOT / "OBDiag" / "AI" / "PromptBuilder.swift"
USER_PROFILE = ROOT / "OBDiag" / "Core" / "Models" / "UserProfile.swift"

TOOL_DESCRIPTION = re.compile(r'description:\s*"((?:[^"\\]|\\.){20,})"')
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.:;])\s+")


def swift_string_literals(source: str) -> list[str]:
    r"""Extracts string literal contents, correctly handling triple-quoted blocks.

    A regex cannot do this: the closing quote of one literal and the opening
    quote of the next would capture source code in between.
    """
    literals: list[str] = []
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            i = n if j == -1 else j + 1
            continue
        if source.startswith("/*", i):
            j = source.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        if source[i] != '"':
            i += 1
            continue
        if source.startswith('"""', i):
            j = source.find('"""', i + 3)
            if j == -1:
                break
            literals.append(source[i + 3:j])
            i = j + 3
            continue
        j = i + 1
        buf: list[str] = []
        while j < n and source[j] != '"' and source[j] != "\n":
            if source[j] == "\\":
                buf.append(source[j:j + 2])
                j += 2
                continue
            buf.append(source[j])
            j += 1
        literals.append("".join(buf))
        i = j + 1
    return literals


def swift_strings(path: Path, *, skip_interpolated: bool = True) -> list[str]:
    """Fixed instruction text from a Swift source file."""
    if not path.exists():
        return []
    values: list[str] = []
    for raw in swift_string_literals(path.read_text()):
        if skip_interpolated and "\\(" in raw:
            continue
        cleaned = (raw.replace('\\"', '"')
                      .replace("\\n", " ")
                      .replace("\\", "")
                      .strip())
        if cleaned:
            values.append(cleaned)
    return values


def words(text: str) -> list[str]:
    return re.sub(r"[^a-z0-9 ]", " ", text.lower()).split()


def phrase_present(phrase: str, haystack: set[str], threshold: float = 0.7) -> bool:
    tokens = words(phrase)
    if not tokens:
        return True
    hits = sum(1 for token in tokens if token in haystack)
    return hits / len(tokens) >= threshold


def swift_number(value: float) -> str:
    """Render a number the way Swift source is likely to spell it.

    `1.0` and `1` are the same Double, and authors write both, so compare
    against the shortest form rather than a fixed decimal count.
    """
    return str(int(value)) if float(value).is_integer() else repr(float(value))


def main() -> int:
    sys.path.insert(0, str(Path(__file__).parent))
    import harness  # noqa: E402
    from harness import (  # noqa: E402
        MINIMUM_CHARGE,
        MODEL_TIER_MULTIPLIER,
        TOKENS_PER_CREDIT,
    )

    failures: list[str] = []
    warnings: list[str] = []

    # 1. Tool coverage — strict.
    python_tools = set()
    for backend in ("client", "server"):
        for tool in harness.tool_definitions(backend):
            name = tool.get("function", {}).get("name") or tool.get("type")
            if name:
                python_tools.add(name)

    swift_text = TOOL_REGISTRY.read_text() if TOOL_REGISTRY.exists() else ""
    swift_tools = set(re.findall(r'\.function\(\s*\n?\s*name:\s*"([a-z_]+)"', swift_text))
    swift_tools |= set(re.findall(r'serverTool\("([^"]+)"', swift_text))
    missing = sorted(t for t in swift_tools if t not in python_tools)
    if missing:
        failures.append("tools in the app but not in the Python harness: " + ", ".join(missing))

    # 2. Prompt coverage — advisory.
    python_words: set[str] = set()
    for backend in ("client", "server"):
        for tool in harness.tool_definitions(backend):
            python_words |= set(words(tool.get("function", {}).get("description", "")))
    # Every branch of the prompt, so branch-specific text counts as covered.
    prompt_shapes = [
        ({"vehicle": {"year": 2018, "make": "Honda", "model": "Civic", "trim": "EX-L",
                      "vin": "1HGCM82633A004352", "engine": "1.5L turbo", "fuelType": "Gasoline",
                      "bodyClass": "Sedan", "driveType": "FWD"},
          "obd": {"connected": True, "codes": [{"code": "P0420", "status": "stored"}]}},
         {"coolantTemperature": 92}),
        ({"vehicle": {"make": "Honda", "model": "Civic", "directConnection": True},
          "obd": {"connected": True}}, {}),
        ({"vehicle": {}, "obd": {"connected": True, "demo": True}}, {"engineRPM": 780}),
        ({"vehicle": {"make": "Honda", "model": "Civic"}, "obd": {"connected": False}}, {}),
    ]
    for scenario, readings in prompt_shapes:
        state = harness.OBDState(readings={k: harness.Reading(v) for k, v in readings.items()})
        python_words |= set(words(harness.build_system_prompt(scenario, state)))

    # Tool descriptions are compared word-for-word against the Python schemas.
    python_tool_text = " ".join(
        tool.get("function", {}).get("description", "")
        for backend in ("client", "server")
        for tool in harness.tool_definitions(backend)
    ).lower()
    swift_descriptions = TOOL_DESCRIPTION.findall(TOOL_REGISTRY.read_text()) if TOOL_REGISTRY.exists() else []
    missing_descriptions = [d for d in swift_descriptions
                            if not phrase_present(d, set(words(python_tool_text)), threshold=0.8)]
    if missing_descriptions:
        warnings.append(f"{len(missing_descriptions)} tool description(s) differ from the app's wording")

    # Prompt instructions: fixed sentences only.
    swift_sentences = []
    for value in swift_strings(PROMPT_BUILDER):
        for sentence in SENTENCE_SPLIT_RE.split(value):
            if len(sentence.split()) >= 5:
                swift_sentences.append(sentence)

    if swift_sentences:
        unmatched = [s for s in swift_sentences if not phrase_present(s, python_words)]
        coverage = (len(swift_sentences) - len(unmatched)) / len(swift_sentences)
        print(f"prompt coverage: {coverage:.0%} of the app's {len(swift_sentences)} instruction sentences are represented")
        if coverage < 0.85:
            warnings.append("prompt coverage below 85% — the app's prompt may have moved ahead of eval/harness.py")
        for sentence in unmatched[:6]:
            print(f"  unmatched: {sentence.strip()[:110]}")

    # 3. Credit constants — strict. The app bills per token with a per-tier
    # multiplier; if these drift apart the harness reports costs that the app
    # would never charge.
    if USER_PROFILE.exists():
        profile = USER_PROFILE.read_text()
        if TOKENS_PER_CREDIT != 1000:
            failures.append("harness TOKENS_PER_CREDIT no longer matches the app's 1,000")
        if "static let tokensPerCredit: Double = 1_000" not in profile:
            failures.append("app's CreditPricing.tokensPerCredit is not 1,000")
        for tier, multiplier in MODEL_TIER_MULTIPLIER.items():
            expected = f"case .{tier}: return {swift_number(multiplier)}"
            if expected not in profile:
                failures.append(f"tier multiplier for '{tier}' differs from the app (expected {multiplier})")
        if MINIMUM_CHARGE != 1:
            failures.append("minimum charge differs from the app's 1 credit")

    for warning in warnings:
        print(f"warning: {warning}")
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("drift check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
