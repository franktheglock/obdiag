import Foundation

/// Builds the system prompt: vehicle identity, fault codes, live snapshot,
/// user style preferences and tool policy. Everything the assistant needs to be
/// specific rather than generic.
enum PromptBuilder {

    @MainActor
    static func systemPrompt(
        vehicle: Vehicle?,
        obd: OBDSession,
        garage: GarageStore,
        settings: AppSettings,
        search: SearchService,
        hasTools: Bool
    ) -> String {
        var sections: [String] = []

        sections.append("""
        You are OBDiag, an expert automotive diagnostic assistant embedded in an iPhone app. \
        You help a car owner understand what is wrong with their vehicle and what to do about it, \
        using the vehicle's actual OBD-II data. You are practical, calm and specific — never \
        alarmist, never vague.
        """)

        // Vehicle profile
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

        // Fault codes
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

        // Live data
        if obd.isConnected {
            let converter = UnitConverter(system: settings.unitSystem)
            var lines = ["## Live data snapshot (metric stored, converted to \(settings.unitSystem.title))"]
            let kinds: [SensorKind] = [.engineRPM, .vehicleSpeed, .coolantTemperature, .intakeAirTemperature,
                                       .engineLoad, .throttlePosition, .batteryVoltage, .massAirFlow,
                                       .manifoldAbsolutePressure, .shortTermFuelTrimBank1, .longTermFuelTrimBank1,
                                       .shortTermFuelTrimBank2, .longTermFuelTrimBank2, .o2Bank1Sensor1,
                                       .fuelLevel, .timingAdvance]
            for kind in kinds {
                guard let reading = obd.reading(kind), reading.isValid else { continue }
                let definition = SensorCatalog.definition(for: kind)
                let health = definition.health(for: reading.value)
                let value = converter.formattedWithUnit(reading.value, kind: definition.measure)
                let age = Int(Date().timeIntervalSince(reading.timestamp))
                lines.append("- \(definition.shortName): \(value) [\(health.label)] (updated \(age)s ago)")
            }
            if obd.isDemo {
                lines.append("- NOTE: this data comes from the built-in demo simulator.")
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

        // Tool policy
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

        // Answer shape
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

        // Personalization
        let style = settings.onboardingAnswers.assistantStyleGuide
        if !style.isBlank {
            sections.append("## Owner preferences\n\(style)")
        }

        sections.append("Current date: \(Date().formatted(date: .complete, time: .shortened)).")
        return sections.joined(separator: "\n\n")
    }
}
