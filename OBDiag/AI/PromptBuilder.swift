import Foundation

/// Builds the system prompt, split for prompt caching.
///
/// The prompt is returned in two blocks because a provider-side prefix cache is
/// invalidated from the first changed byte onward:
///
///   * `stable`   — byte-identical across every turn of a session. This is the
///                  block a cache can reuse, so nothing time- or data-dependent
///                  may go in it.
///   * `volatile` — vehicle, fault codes and connection state. Rebuilt each
///                  turn, and deliberately kept last and small, because every
///                  token here is re-billed at full input price on every turn.
///
/// The previous layout ordered sections persona → vehicle → codes → live data →
/// tools → style. Live sensor readings embed a per-second age, so they
/// invalidated the tool policy, the answer style and the owner preferences that
/// followed them — leaving a cacheable prefix of about 60 tokens instead of
/// ~3,000, i.e. nothing worth caching ever hit.
///
/// Two rules keep this cacheable:
///   1. Anything that varies goes in `volatile`, after every fixed section.
///   2. `stable` must not interpolate anything that changes between turns.
enum PromptBuilder {

    /// Two-part system prompt. `combined` is the flat text used by callers that
    /// don't care about caching (the eval harness replica, previews).
    struct SystemPrompt {
        var stable: String
        var volatile: String

        var combined: String {
            volatile.isEmpty ? stable : stable + "\n\n" + volatile
        }
    }

    @MainActor
    static func systemPrompt(
        vehicle: Vehicle?,
        obd: OBDSession,
        garage: GarageStore,
        settings: AppSettings,
        search: SearchService,
        hasTools: Bool
    ) -> SystemPrompt {
        SystemPrompt(
            stable: stableSections(settings: settings, hasTools: hasTools),
            volatile: volatileSections(vehicle: vehicle, obd: obd, settings: settings)
        )
    }

    // MARK: - Stable (cacheable) block

    /// Fixed text only. Nothing here may depend on the current time, live sensor
    /// values, or fault codes, or the cache will miss on every turn.
    @MainActor
    private static func stableSections(settings: AppSettings, hasTools: Bool) -> String {
        var sections: [String] = []

        sections.append("""
        You are OBDiag, an expert automotive diagnostic assistant embedded in an iPhone app. \
        You help a car owner understand what is wrong with their vehicle and what to do about it, \
        using the vehicle's actual OBD-II data. You are practical, calm and specific — never \
        alarmist, never vague.
        """)

        // Tool policy. Depends only on which tools are enabled in Settings, which
        // is stable for the life of a session.
        if hasTools {
            var lines = ["## Tools"]
            lines.append("Use tools instead of guessing. In particular:")
            lines.append("- `get_fault_codes` and `get_live_data` for anything about the actual car. Prefer calling them before answering diagnostic questions.")
            if settings.webSearchEnabled {
                lines.append("- Web search for recalls, TSBs, specs, fluid capacities, torque values, part numbers and procedures. Manufacturer-specific data changes by model year — verify it.")
            }
            if settings.videoSearchEnabled {
                lines.append("- `search_videos` when a visual walkthrough would help a DIY repair.")
            }
            if settings.partsSearchEnabled {
                lines.append("- `search_parts` for purchase links, current prices and tool recommendations.")
            }
            if settings.urlReadingEnabled {
                lines.append("- Read specific URLs when a search snippet is not enough.")
            }
            if settings.askUserEnabled {
                lines.append("- `ask_user` when a missing fact (symptom timing, recent work, tools on hand) blocks a reliable answer. Ask at most one focused question and offer concrete options.")
            }
            lines.append("Never invent part numbers, torque specs or TSB numbers. If you could not verify something, say so explicitly.")
            sections.append(lines.joined(separator: "\n"))
        }

        // Answer shape. Unit system and region are user settings, stable across
        // a session, so they can live in the cached block.
        sections.append("""
        ## Answer style
        - Lead with the bottom line: what it means and how urgent it is.
        - Structure longer answers with short markdown headings, e.g. **What it means**, **Likely causes**, **Check this**, **Parts & tools**, **Watch this**. Skip headings for simple replies.
        - End with a concrete next action the owner can take, and what to watch for afterwards.
        - Prefer bullets over paragraphs. Keep it tight.
        - When you used sources, cite them inline as markdown links and list the best 3-5 at the end under "Sources".
        - Use the user's units (\(settings.unitSystem.title)) and a \(settings.regionCode) context.
        - The user can attach photos (warning lights, leaks, damaged parts, labels, scan-tool screens). When a photo is present, say what you observe in it and tie that to the data before advising.
        - Never advise disabling emissions equipment. Flag safety-critical issues (brakes, steering, fuel leaks, overheating, airbags) clearly and tell the owner to stop driving when appropriate.
        """)

        // Personalization.
        let style = settings.onboardingAnswers.assistantStyleGuide
        if !style.isBlank {
            sections.append("## Owner preferences\n\(style)")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Volatile block

    /// Everything that can change between turns. Ordered least → most volatile
    /// so that, if a provider supports several cache breakpoints, the maximum
    /// shared prefix still matches.
    @MainActor
    private static func volatileSections(
        vehicle: Vehicle?,
        obd: OBDSession,
        settings: AppSettings
    ) -> String {
        var sections: [String] = []

        // Vehicle profile — stable for a whole conversation, changes only when
        // the user switches vehicles.
        if let vehicle {
            var lines = ["## Vehicle"]
            lines.append("- \(vehicle.fullName)")
            if let vin = vehicle.vin, !vin.isBlank { lines.append("- VIN: \(vin)") }
            if let engine = vehicle.engineDescription, !engine.isBlank { lines.append("- Engine: \(engine)") }
            if let fuel = vehicle.fuelType, !fuel.isBlank { lines.append("- Fuel: \(fuel)") }
            if let body = vehicle.bodyClass, !body.isBlank { lines.append("- Body: \(body)") }
            if let drive = vehicle.driveType, !drive.isBlank { lines.append("- Drive: \(drive)") }
            if vehicle.isDirectConnection {
                lines.append("- The user has not set up a specific vehicle; ask or infer from VIN/engine data when relevant.")
            }
            sections.append(lines.joined(separator: "\n"))
        } else {
            sections.append("## Vehicle\nNo vehicle has been set up yet. Ask only if vehicle specifics are essential.")
        }

        // Fault codes — change whenever the user scans or clears codes.
        if obd.isConnected || obd.lastDTCScan != nil {
            var lines = ["## Current fault codes"]
            if obd.dtcs.isEmpty {
                lines.append("No stored, pending or permanent codes are present.")
            } else {
                for code in obd.dtcs {
                    var entry = "- \(code.code) [\(code.status.title), \(code.severity.title)] \(code.title)"
                    if !code.possibleCauses.isEmpty {
                        entry += " Likely causes: \(code.possibleCauses.prefix(4).joined(separator: "; "))."
                    }
                    lines.append(entry)
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // Connection state.
        //
        // This deliberately does NOT include a live sensor snapshot. Readings
        // change continuously and the old block stamped each one with an age in
        // seconds, which alone was enough to invalidate the whole cache on every
        // turn. The model is already instructed above to call `get_live_data`
        // before answering diagnostic questions, and anything it fetches lands in
        // the conversation transcript where it can be cached properly.
        if obd.isConnected {
            var lines = ["## Connection"]
            lines.append("An OBD-II adapter is connected. Call `get_live_data` for current sensor readings and `get_fault_codes` for present codes before diagnosing.")
            if obd.isDemo {
                lines.append("The adapter is the built-in demo simulator, so treat the values as illustrative rather than from a real vehicle.")
            }
            sections.append(lines.joined(separator: "\n"))
        } else {
            sections.append("""
            ## Connection
            No OBD adapter is connected, so live data and fresh code scans are unavailable. \
            The user can connect an adapter or enable demo mode from the dashboard. The tools \
            `get_live_data` and `get_fault_codes` will report that state.
            """)
        }

        // Date last: it rolls over at midnight, so nothing may follow it.
        sections.append("Current date: \(Date().formatted(date: .complete, time: .omitted)).")

        return sections.joined(separator: "\n\n")
    }
}
