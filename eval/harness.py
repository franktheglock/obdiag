"""OBDiag agent harness — a faithful, dependency-free replica of the app's
assistant pipeline.

It mirrors:
  * `PromptBuilder.systemPrompt(...)`      (system prompt assembly)
  * `ToolExecutor.toolDefinitions(...)`    (tool schemas)
  * `ChatEngine.run(...)`                  (stream -> tools -> repeat, max 6 turns)
  * `CreditPricing.credits(...)`           (credit accounting)

Tool *results* come from fixtures so groundedness can be graded exactly; only
the model call goes to the network.

Run `python3 eval/run.py --help` for usage.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Optional

# python.org Python builds ship without a wired-up CA bundle, so urllib fails
# with CERTIFICATE_VERIFY_FAILED on a machine where curl works fine. Point
# OpenSSL at certifi when it's installed and nothing has been chosen already.
try:  # pragma: no cover - environment dependent
    import certifi  # type: ignore

    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
except Exception:  # pragma: no cover
    pass

# OpenAI-compatible endpoint. Override the base URL to evaluate a model served
# somewhere other than OpenRouter — RunInfra, for instance — without touching the
# harness:
#
#   OBDIAG_EVAL_BASE_URL=https://api.runinfra.ai/v1 \
#   OBDIAG_EVAL_KEY=... python3 eval/run.py --models glm-5-3-flash
BASE_URL = os.environ.get("OBDIAG_EVAL_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")
OPENROUTER_URL = f"{BASE_URL}/chat/completions"

MAX_TURNS = 6  # mirrors ChatEngine's tool-call cap

# ---------------------------------------------------------------------------
# Tool schemas — keep in sync with ToolExecutor.toolDefinitions
# ---------------------------------------------------------------------------

def tool_definitions(search_backend: str = "client") -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = []

    if search_backend == "server":
        tools.append({"type": "openrouter:web_search", "parameters": {
            "engine": "auto", "max_results": 6, "max_uses": 3, "search_context_size": "medium"}})
    else:
        tools.append(_fn("web_search",
                         "Search the web for facts, recalls, technical service bulletins, torque specs, fluid capacities "
                         "and repair procedures. Prefer this over guessing. Cite the URLs you use.",
                         {"query": _str("The search query, specific to this vehicle when possible."),
                          "why": _str("Optional one-line reason for the search, used to rank results.")},
                         ["query"]))

    tools.append(_fn("search_videos",
                     "Find repair walkthrough videos (YouTube and Vimeo). Use when a visual procedure would help, "
                     "and include the best video links in your answer.",
                     {"query": _str("What the video should show.")}, ["query"]))

    tools.append(_fn("search_parts",
                     "Find parts, tools and fluids for purchase with current listings and prices from major retailers. "
                     "Include the part names and links in your answer.",
                     {"query": _str("The part or tool to find, including year/make/model and engine."),
                      "category": _str("Optional category filter.", ["part", "tool", "fluid", "accessory"])},
                     ["query"]))

    if search_backend == "server":
        tools.append({"type": "openrouter:web_fetch",
                      "parameters": {"max_uses": 4, "max_content_tokens": 30000}})
    else:
        tools.append(_fn("read_url", "Fetch a specific URL (repair guide, forum thread, listing, PDF page) and return its readable text.",
                         {"url": _str("The full http(s) URL to read.")}, ["url"]))

    tools.append(_fn("get_live_data",
                     "Read the vehicle's live OBD-II sensor values right now (engine speed, coolant temperature, fuel trims, "
                     "O2 sensors, battery voltage and more). Call this before commenting on how the engine is running, "
                     "and again after the user changes something.",
                     {"sensors": {"type": "array", "description": "Optional sensor kinds to read.",
                                  "items": _str("Sensor kind")}}, []))

    tools.append(_fn("get_fault_codes",
                     "Read stored, pending and permanent diagnostic trouble codes (DTCs) from the ECU, with their severity "
                     "and on-device descriptions. Use this whenever the user mentions a warning light or asks what is "
                     "wrong with the car.",
                     {}, []))

    tools.append(_fn("ask_user",
                     "Ask the user a multiple-choice question when missing information blocks a reliable answer (symptoms, "
                     "when it happens, recent work, tools available). Keep it to one focused question and offer "
                     "concrete options.",
                     {"question": _str("The question to ask."),
                      "header": _str("Short label, 1-3 words."),
                      "options": {"type": "array", "description": "Two to five concrete answers.",
                                  "items": {"type": "object", "properties": {
                                      "label": _str("Answer text."),
                                      "detail": _str("Optional clarification."),
                                      "recommended": {"type": "boolean"}},
                                      "required": ["label"]}},
                      "allow_multiple": {"type": "boolean"},
                      "allow_freeform": {"type": "boolean"}},
                     ["question", "options"]))

    return tools


def _fn(name: str, description: str, properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
    return {"type": "function", "function": {
        "name": name,
        "description": description,
        "parameters": {"type": "object", "properties": properties, "required": required}}}


def _str(description: str, enum: Optional[list[str]] = None) -> dict[str, Any]:
    schema: dict[str, Any] = {"type": "string", "description": description}
    if enum:
        schema["enum"] = enum
    return schema


# ---------------------------------------------------------------------------
# System prompt — mirrors PromptBuilder.systemPrompt
# ---------------------------------------------------------------------------

# Sensor metadata used to render the live-data snapshot exactly like the app:
# short name, unit, and the thresholds from SensorCatalog. `warn` maps to the
# app's "High" health label, `critical` to "Critical".
SENSORS: dict[str, dict[str, object]] = {
    "engineRPM":                    {"short": "RPM",       "measure": "rpm",   "warn": (None, 6200), "critical": (None, 7200)},
    "vehicleSpeed":                 {"short": "Speed",     "measure": "kph"},
    "engineLoad":                   {"short": "Load",      "measure": "percent", "warn": (None, 92)},
    "absoluteLoad":                 {"short": "Abs load",  "measure": "percent", "warn": (None, 95)},
    "throttlePosition":             {"short": "Throttle",  "measure": "percent"},
    "timingAdvance":                {"short": "Timing",    "measure": "degrees"},
    "runtimeSinceStart":            {"short": "Run time",  "measure": "seconds"},
    "engineOilTemperature":         {"short": "Oil temp",  "measure": "celsius", "warn": (None, 130), "critical": (None, 155)},
    "coolantTemperature":           {"short": "Coolant",   "measure": "celsius", "warn": (None, 106), "critical": (None, 118)},
    "intakeAirTemperature":         {"short": "Intake air","measure": "celsius", "warn": (None, 65), "critical": (None, 90)},
    "ambientAirTemperature":        {"short": "Ambient",   "measure": "celsius"},
    "catalystTempBank1Sensor1":     {"short": "Cat B1S1",  "measure": "celsius", "warn": (None, 950)},
    "catalystTempBank1Sensor2":     {"short": "Cat B1S2",  "measure": "celsius", "warn": (None, 950)},
    "manifoldAbsolutePressure":     {"short": "MAP",       "measure": "kpa"},
    "boostPressure":                {"short": "Boost",     "measure": "kpa"},
    "massAirFlow":                  {"short": "MAF",       "measure": "airflow"},
    "fuelPressure":                 {"short": "Fuel press","measure": "kpa"},
    "fuelLevel":                    {"short": "Fuel",      "measure": "percent", "warn": (10, None)},
    "barometricPressure":           {"short": "Baro",      "measure": "kpa"},
    "shortTermFuelTrimBank1":       {"short": "STFT B1",   "measure": "percent", "warn": (-15, 15), "critical": (-30, 30)},
    "longTermFuelTrimBank1":        {"short": "LTFT B1",   "measure": "percent", "warn": (-12, 12), "critical": (-25, 25)},
    "shortTermFuelTrimBank2":       {"short": "STFT B2",   "measure": "percent", "warn": (-15, 15), "critical": (-30, 30)},
    "longTermFuelTrimBank2":        {"short": "LTFT B2",   "measure": "percent", "warn": (-12, 12), "critical": (-25, 25)},
    "o2Bank1Sensor1":               {"short": "O₂ B1S1",   "measure": "volts"},
    "o2Bank1Sensor2":               {"short": "O₂ B1S2",   "measure": "volts"},
    "o2Bank2Sensor1":               {"short": "O₂ B2S1",   "measure": "volts"},
    "o2Bank2Sensor2":               {"short": "O₂ B2S2",   "measure": "volts"},
    "batteryVoltage":               {"short": "Battery",   "measure": "volts", "warn": (12.4, 15.0), "critical": (11.6, None)},
}

# Unit conversion mirrors UnitConverter: values are stored metric and rendered
# in the user's system.
IMPERIAL = {
    "celsius": (lambda v: v * 9 / 5 + 32, "°F"),
    "kph": (lambda v: v * 0.621371, "mph"),
    "kpa": (lambda v: v * 0.145038, "psi"),
    "airflow": (lambda v: v * 0.132277, "lb/min"),
}
METRIC_SYMBOLS = {"celsius": "°C", "kph": "km/h", "kpa": "kPa", "airflow": "g/s",
                  "percent": "%", "volts": "V", "rpm": "rpm", "degrees": "°", "seconds": "s"}


def build_system_prompt(scenario: dict[str, Any], obd_state: "OBDState", *, has_tools: bool = True,
                        units: str = "imperial") -> str:
    """Mirrors `PromptBuilder.systemPrompt`.

    Split into a stable block (cacheable: nothing in it may vary between turns)
    and a volatile block (vehicle, codes, connection, date). The app sends these
    as two content blocks with a prompt-cache breakpoint between them; the
    replica only needs the text, but it keeps the same split so drift in either
    half is visible.

    Note there is deliberately no live sensor snapshot. The app removed it: the
    readings churn continuously and the per-second age stamp invalidated the
    whole cacheable prefix on every turn. The model is told to call
    `get_live_data` instead.
    """
    sections = _stable_prompt_sections(has_tools, units, scenario)
    sections += _volatile_prompt_sections(scenario, obd_state, units)
    return "\n\n".join(sections)


def _stable_prompt_sections(has_tools: bool, units: str, scenario: dict[str, Any]) -> list[str]:
    """Fixed text. Must stay byte-identical across turns or the cache misses."""
    sections: list[str] = []

    sections.append(
        "You are OBDiag, an expert automotive diagnostic assistant embedded in an iPhone app. "
        "You help a car owner understand what is wrong with their vehicle and what to do about it, "
        "using the vehicle's actual OBD-II data. You are practical, calm and specific — never "
        "alarmist, never vague."
    )

    if has_tools:
        sections.append("\n".join([
            "## Tools",
            "Use tools instead of guessing. In particular:",
            "- `get_fault_codes` and `get_live_data` for anything about the actual car. Prefer calling them before answering diagnostic questions.",
            "- Web search for recalls, TSBs, specs, fluid capacities, torque values, part numbers and procedures. Manufacturer-specific data changes by model year — verify it.",
            "- `search_videos` when a visual walkthrough would help a DIY repair.",
            "- `search_parts` for purchase links, current prices and tool recommendations.",
            "- Read specific URLs when a search snippet is not enough.",
            "- `ask_user` when a missing fact (symptom timing, recent work, tools on hand) blocks a reliable answer. Ask at most one focused question and offer concrete options.",
            "Never invent part numbers, torque specs or TSB numbers. If you could not verify something, say so explicitly.",
        ]))

    sections.append("\n".join([
        "## Answer style",
        "- Lead with the bottom line: what it means and how urgent it is.",
        "- Structure longer answers with short markdown headings, e.g. **What it means**, **Likely causes**, **Check this**, **Parts & tools**, **Watch this**. Skip headings for simple replies.",
        "- End with a concrete next action the owner can take, and what to watch for afterwards.",
        "- Prefer bullets over paragraphs. Keep it tight.",
        "- When you used sources, cite them inline as markdown links and list the best 3-5 at the end under \"Sources\".",
        f"- Use the user's units ({units.title()}) and a US context.",
        "- The user can attach photos (warning lights, leaks, damaged parts, labels, scan-tool screens). When a photo is present, say what you observe in it and tie that to the data before advising.",
        "- Never advise disabling emissions equipment. Flag safety-critical issues (brakes, steering, fuel leaks, overheating, airbags) clearly and tell the owner to stop driving when appropriate.",
    ]))

    style = scenario.get("onboarding", {}).get("style_guide")
    if style:
        sections.append(f"## Owner preferences\n{style}")

    return sections


def _volatile_prompt_sections(scenario: dict[str, Any], obd_state: "OBDState",
                              units: str) -> list[str]:
    """Everything that can change between turns, least volatile first."""
    vehicle = scenario.get("vehicle", {})
    obd = scenario.get("obd", {})
    sections: list[str] = []

    if vehicle:
        lines = ["## Vehicle"]
        name = " ".join(str(x) for x in [vehicle.get("year"), vehicle.get("make"), vehicle.get("model")] if x)
        if vehicle.get("trim"):
            name += f" • {vehicle['trim']}"
        lines.append(f"- {name}".rstrip())
        if vehicle.get("vin"):
            lines.append(f"- VIN: {vehicle['vin']}")
        if vehicle.get("engine"):
            lines.append(f"- Engine: {vehicle['engine']}")
        if vehicle.get("fuelType"):
            lines.append(f"- Fuel: {vehicle['fuelType']}")
        if vehicle.get("bodyClass"):
            lines.append(f"- Body: {vehicle['bodyClass']}")
        if vehicle.get("driveType"):
            lines.append(f"- Drive: {vehicle['driveType']}")
        if vehicle.get("directConnection"):
            lines.append("- The user has not set up a specific vehicle; ask or infer from VIN/engine data when relevant.")
        sections.append("\n".join(lines))
    else:
        sections.append("## Vehicle\nNo vehicle has been set up yet. Ask only if vehicle specifics are essential.")

    if obd.get("connected", True):
        code_lines = ["## Current fault codes"]
        codes = obd.get("codes") or []
        if not codes:
            code_lines.append("No stored, pending or permanent codes are present.")
        else:
            db = _dtc_db()
            for c in codes:
                status = c.get("status", "stored").title()
                entry = db.get(c["code"].upper(), {})
                severity = str(entry.get("severity", "moderate")).title()
                title = entry.get("title", "")
                line = f"- {c['code']} [{status}, {severity}] {title}".rstrip()
                causes = entry.get("causes") or []
                if causes:
                    line += " Likely causes: " + "; ".join(causes[:4]) + "."
                code_lines.append(line)
        sections.append("\n".join(code_lines))

        connection = ["## Connection",
                      "An OBD-II adapter is connected. Call `get_live_data` for current sensor readings "
                      "and `get_fault_codes` for present codes before diagnosing."]
        if obd.get("demo"):
            connection.append("The adapter is the built-in demo simulator, so treat the values as "
                              "illustrative rather than from a real vehicle.")
        sections.append("\n".join(connection))
    else:
        sections.append(
            "## Connection\n"
            "No OBD adapter is connected, so live data and fresh code scans are unavailable. "
            "The user can connect an adapter or enable demo mode from the dashboard. The tools "
            "`get_live_data` and `get_fault_codes` will report that state."
        )

    from datetime import datetime
    sections.append("Current date: " + datetime.now().strftime("%A, %B %-d, %Y") + ".")

    return sections


def render_reading(kind: str, value: float, units: str) -> Optional[str]:
    meta = SENSORS.get(kind)
    if not meta:
        return None
    measure = str(meta["measure"])
    if units == "imperial" and measure in IMPERIAL:
        convert, symbol = IMPERIAL[measure]
        rendered = convert(value)
    else:
        symbol = METRIC_SYMBOLS.get(measure, "")
        rendered = value

    decimals = 2 if measure == "volts" else (0 if measure in ("rpm", "seconds") else (1 if abs(rendered) < 100 else 0))
    text = f"{rendered:.{decimals}f}"
    health = _health(meta, value)
    return f"- {meta['short']}: {text} {symbol} [{health}] (updated 0s ago)"


def _health(meta: dict[str, object], value: float) -> str:
    critical = meta.get("critical")
    if critical:
        low, high = critical  # type: ignore[misc]
        if (low is not None and value < low) or (high is not None and value > high):
            return "Critical"
    warn = meta.get("warn")
    if warn:
        low, high = warn  # type: ignore[misc]
        if (low is not None and value < low) or (high is not None and value > high):
            return "High"
    return "Normal"


def _dtc_db() -> dict[str, Any]:
    from graders import dtc_knowledge
    return dtc_knowledge()


# ---------------------------------------------------------------------------
# Fixture tool execution — mirrors ToolExecutor.execute
# ---------------------------------------------------------------------------

@dataclass
class Reading:
    value: float


@dataclass
class OBDState:
    connected: bool = True
    adapter: str = "Fixture Adapter"
    readings: dict[str, Reading] = field(default_factory=dict)

    def as_json(self) -> dict[str, Any]:
        sensors = []
        for kind, reading in self.readings.items():
            label, unit = SENSOR_LABELS.get(kind, (kind, ""))
            sensors.append({"kind": kind, "name": label, "value": reading.value, "unit": unit, "status": "Normal"})
        return {"connected": self.connected, "demo": False, "adapter": self.adapter,
                "sensors": sensors, "faultCodeCount": 0}


class ToolRunner:
    """Executes the assistant's tool calls against scenario fixtures."""

    def __init__(self, scenario: dict[str, Any], obd_state: OBDState):
        self.scenario = scenario
        self.obd = obd_state
        self.asked_questions: list[dict[str, Any]] = []

    def execute(self, name: str, arguments: dict[str, Any]) -> tuple[str, bool]:
        """Returns (result_json, is_error)."""
        try:
            if name == "get_fault_codes":
                return self._fault_codes(), False
            if name == "get_live_data":
                return self._live_data(), False
            if name == "web_search":
                return self._search(arguments.get("query", ""), scope="web"), False
            if name == "search_videos":
                return self._search(arguments.get("query", ""), scope="videos"), False
            if name == "search_parts":
                return self._search(arguments.get("query", ""), scope="parts"), False
            if name == "read_url":
                return self._read_url(arguments.get("url", "")), False
            if name == "ask_user":
                self.asked_questions.append(arguments)
                answer = self.scenario.get("autoAnswer") or "Not sure"
                return json.dumps({"question": arguments.get("question", ""), "answer": answer,
                                   "answered": True}), False
            return json.dumps({"error": f"Unknown tool {name}"}), True
        except Exception as exc:  # fixtures should never crash the run
            return json.dumps({"error": str(exc)}), True

    # -- individual tools -------------------------------------------------

    def _fault_codes(self) -> str:
        if not self.obd.connected:
            return json.dumps({"connected": False, "stored": [], "pending": [], "permanent": [],
                               "note": "No adapter is connected."})
        codes = self.scenario.get("obd", {}).get("codes", [])
        buckets: dict[str, list[dict[str, Any]]] = {"stored": [], "pending": [], "permanent": []}
        for c in codes:
            record = {"code": c["code"], "status": c.get("status", "stored")}
            buckets.setdefault(record["status"], []).append(record)
        return json.dumps({"connected": True, "vehicle": _vehicle_name(self.scenario),
                           "scannedAt": "now", **buckets})

    def _live_data(self) -> str:
        if not self.obd.connected:
            return json.dumps({"connected": False, "sensors": [],
                               "note": "No adapter is connected."})
        return json.dumps(self.obd.as_json())

    def _search(self, query: str, scope: str) -> str:
        needle = query.lower()
        results: list[dict[str, Any]] = []
        for fixture in self.scenario.get("searchFixtures", []):
            if fixture.get("scope") and fixture["scope"] != scope:
                continue
            if not any(keyword.lower() in needle for keyword in fixture.get("matchAny", [])):
                continue
            for r in fixture.get("results", []):
                results.append({"title": r["title"], "url": r["url"], "site": _host(r["url"]),
                                "snippet": r["snippet"]})
        if not results:
            return json.dumps({"query": query, "backend": "fixtures", "results": [],
                               "note": "No results were returned for this query."})
        return json.dumps({"query": query, "backend": "fixtures", "results": results,
                           "note": "Cite the URLs you rely on using markdown links."})

    def _read_url(self, url: str) -> str:
        for fixture in self.scenario.get("searchFixtures", []):
            for r in fixture.get("results", []):
                if url and (url in r["url"] or r["url"] in url):
                    return json.dumps({"url": r["url"], "title": r["title"], "content": r["snippet"]})
        return json.dumps({"error": "That page could not be read."})


# ---------------------------------------------------------------------------
# OpenRouter client (non-streaming; returns tool calls + usage in one response)
# ---------------------------------------------------------------------------

class OpenRouter:
    def __init__(self, api_key: str, timeout: int = 120):
        self.api_key = api_key
        self.timeout = timeout

    def complete(self, *, model: str, messages: list[dict[str, Any]],
                 tools: list[dict[str, Any]], temperature: Optional[float] = None) -> dict[str, Any]:
        payload: dict[str, Any] = {"model": model, "messages": messages, "usage": {"include": True}}
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        if temperature is not None:
            payload["temperature"] = temperature

        request = urllib.request.Request(
            OPENROUTER_URL,
            data=json.dumps(payload).encode(),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://obdiag.app",
                "X-Title": "OBDiag Eval",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read().decode())
        except urllib.error.HTTPError as err:
            body = err.read().decode()[:400]
            raise RuntimeError(f"HTTP {err.code}: {body}") from err
        except urllib.error.URLError as err:
            raise RuntimeError(f"Network error: {err.reason}") from err


# ---------------------------------------------------------------------------
# Agent loop — mirrors ChatEngine.run
# ---------------------------------------------------------------------------

@dataclass
class ToolCall:
    id: str
    name: str
    arguments: str


@dataclass
class Turn:
    text: str = ""
    reasoning: str = ""
    tool_calls: list[ToolCall] = field(default_factory=list)
    usage: dict[str, Any] = field(default_factory=dict)
    finish_reason: Optional[str] = None


@dataclass
class RunResult:
    scenario_id: str
    scenario_title: str
    category: str
    model_id: str
    model_name: str
    turns: list[Turn]
    final_text: str
    tool_names: list[str]
    tool_corpus: str
    prompt_tokens: int
    completion_tokens: int
    cached_tokens: int
    cost_usd: float
    credits: int
    latency: float
    error: Optional[str] = None

    @property
    def timed_out(self) -> bool:
        return False


class AgentHarness:
    def __init__(self, client: OpenRouter, scenario: dict[str, Any], model: dict[str, Any],
                 *, temperature: Optional[float] = 0.2, units: str = "imperial",
                 search_backend: str = "client"):
        self.client = client
        self.scenario = scenario
        self.model = model
        self.temperature = temperature
        self.units = units
        self.search_backend = search_backend

        obd = scenario.get("obd", {})
        self.obd_state = OBDState(
            connected=obd.get("connected", True),
            adapter=obd.get("adapterName", "Fixture Adapter"),
            readings={k: Reading(v) for k, v in (obd.get("readings") or {}).items()},
        )
        self.tools = ToolRunner(scenario, self.obd_state)
        self.tool_definitions = tool_definitions(search_backend)

    def run(self) -> RunResult:
        import time

        messages: list[dict[str, Any]] = [
            {"role": "system", "content": build_system_prompt(
                self.scenario, self.obd_state, has_tools=bool(self.tool_definitions), units=self.units)}
        ]
        for turn in self.scenario.get("history", []):
            messages.append({"role": "user", "content": turn["user"]})
            messages.append({"role": "assistant", "content": turn["assistant"]})

        user_text = self.scenario.get("prompt", "")
        if self.scenario.get("attachImage"):
            user_text = ("[The user attached 1 image. Read it and use what you see.]\n\n" + user_text)
        messages.append({"role": "user", "content": user_text})

        turns: list[Turn] = []
        tool_names: list[str] = []
        corpus: list[str] = []
        prompt_tokens = completion_tokens = cached_tokens = 0
        cost = 0.0
        error: Optional[str] = None
        started = time.time()

        for _ in range(MAX_TURNS):
            try:
                response = self.client.complete(
                    model=self.model["id"], messages=messages,
                    tools=self.tool_definitions, temperature=self.temperature)
            except Exception as exc:
                error = str(exc)
                break

            choice = (response.get("choices") or [{}])[0]
            message = choice.get("message", {})
            usage = response.get("usage") or {}
            prompt_tokens += usage.get("prompt_tokens", 0)
            completion_tokens += usage.get("completion_tokens", 0)
            cached_tokens += ((usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0)
            cost += usage.get("cost") or 0

            calls = [
                ToolCall(id=c.get("id", f"call_{i}"), name=c.get("function", {}).get("name", ""),
                         arguments=c.get("function", {}).get("arguments", "{}"))
                for i, c in enumerate(message.get("tool_calls") or [])
            ]
            turn = Turn(text=message.get("content") or "",
                        reasoning=message.get("reasoning") or "",
                        tool_calls=calls, usage=usage, finish_reason=choice.get("finish_reason"))
            turns.append(turn)

            if not calls:
                break

            messages.append({
                "role": "assistant",
                "content": turn.text or None,
                "tool_calls": [{"id": c.id, "type": "function",
                                "function": {"name": c.name, "arguments": c.arguments}} for c in calls],
            })
            for call in calls:
                tool_names.append(call.name)
                try:
                    arguments = json.loads(call.arguments or "{}")
                except json.JSONDecodeError:
                    arguments = {}
                result, _ = self.tools.execute(call.name, arguments)
                corpus.append(result)
                messages.append({"role": "tool", "tool_call_id": call.id, "name": call.name, "content": result})

        latency = time.time() - started
        final_text = next((t.text for t in reversed(turns) if t.text.strip()), "")
        return RunResult(
            scenario_id=self.scenario["id"], scenario_title=self.scenario.get("title", ""),
            category=self.scenario.get("category", ""), model_id=self.model["id"],
            model_name=self.model.get("name", self.model["id"]), turns=turns, final_text=final_text,
            tool_names=tool_names, tool_corpus="\n".join(corpus),
            prompt_tokens=prompt_tokens, completion_tokens=completion_tokens,
            cached_tokens=cached_tokens, cost_usd=cost,
            credits=credits_for(prompt_tokens + completion_tokens, self.model), latency=latency, error=error,
        )


# ---------------------------------------------------------------------------
# Credits — mirrors CreditPricing (app) and plans.ts (server)
# ---------------------------------------------------------------------------
#
# Billing is token-pegged, not dollar-pegged:
#
#     credits = max(1, ceil(tokens / 1000 * tier_multiplier))
#
# The multiplier belongs to the *model tier*, not the plan. The plan only
# decides the monthly allowance and the highest tier it may call.
#
# Note this bills *all* tokens, including prompt-cache reads. The provider
# charges far less for a cache hit, so caching widens margin without changing
# what the user pays — which is why the hit rate is worth measuring.

TOKENS_PER_CREDIT = 1000
MINIMUM_CHARGE = 1
MODEL_TIER_MULTIPLIER = {"flash": 0.33, "plus": 1.0, "max": 5.0}
PLAN_MAX_MODEL_TIER = {"free": "flash", "plus": "plus", "pro": "max"}


def tier_for_price(prompt_price_per_million: float, is_free: bool = False) -> str:
    """Flash < $1/M · Plus $1–5/M · Max > $5/M. Mirrors the app's rule."""
    if is_free or prompt_price_per_million <= 0:
        return "flash"
    if prompt_price_per_million < 1:
        return "flash"
    if prompt_price_per_million <= 5:
        return "plus"
    return "max"


def credits_for(tokens: int, model: dict[str, Any]) -> int:
    import math

    if tokens <= 0:
        return 0
    tier = tier_for_price(model.get("inputPrice", 0.0), bool(model.get("isFree", False)))
    raw = tokens / TOKENS_PER_CREDIT * MODEL_TIER_MULTIPLIER[tier]
    return max(MINIMUM_CHARGE, math.ceil(raw))


# ---------------------------------------------------------------------------

def _vehicle_name(scenario: dict[str, Any]) -> str:
    v = scenario.get("vehicle", {})
    return " ".join(str(x) for x in [v.get("year"), v.get("make"), v.get("model")] if x)


def _host(url: str) -> str:
    return re.sub(r"^https?://(www\.)?", "", url).split("/")[0]
