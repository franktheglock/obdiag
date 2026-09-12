import Foundation

/// A tool call parsed from a streamed model response.
struct ToolInvocation: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var arguments: JSONValue

    var argumentsSummary: String {
        let text = arguments.jsonString
        return text == "{}" ? "" : text.truncated(to: 200)
    }
}

/// What a tool returns to the model, plus presentation metadata for the UI.
struct ToolOutcome: Sendable {
    var content: String
    var isError: Bool = false
    var displayName: String
    var systemImage: String

    static func error(_ message: String, displayName: String, systemImage: String) -> ToolOutcome {
        ToolOutcome(content: JSONValue.object(["error": .string(message)]).jsonString,
                    isError: true, displayName: displayName, systemImage: systemImage)
    }
}

/// Tool schemas and execution. Web/video/parts/search tools route through
/// `SearchService` (DuckDuckGo, TinyFish or OpenRouter server tools); OBD tools
/// read the live session; `ask_user` bridges to the UI.
@MainActor
final class ToolExecutor {
    private let obd: OBDSession
    private let garage: GarageStore
    private let search: SearchService
    private let settings: AppSettings

    /// Set by `ChatEngine` to present a multiple-choice question and await the answer.
    var askUser: ((AskUserQuestion) async -> String)?

    init(obd: OBDSession, garage: GarageStore, search: SearchService, settings: AppSettings) {
        self.obd = obd
        self.garage = garage
        self.search = search
        self.settings = settings
    }

    // MARK: Definitions

    static func toolDefinitions(
        searchService: SearchService,
        settings: AppSettings
    ) -> [ToolDefinition] {
        var tools: [ToolDefinition] = []

        // Web search: server-side when OpenRouter is configured for it.
        if settings.webSearchEnabled {
            if searchService.useServerWebSearch {
                tools.append(.serverTool("openrouter:web_search", parameters: .object([
                    "engine": .string("auto"),
                    "max_results": .number(6),
                    "max_uses": .number(3),
                    "search_context_size": .string("medium")
                ])))
            } else {
                tools.append(webSearchTool)
            }
        }

        if settings.videoSearchEnabled {
            tools.append(videoSearchTool)
        }

        if settings.partsSearchEnabled {
            tools.append(partsSearchTool)
        }

        if settings.urlReadingEnabled {
            if settings.provider == .openRouter, !settings.openRouterAPIKey.isBlank {
                tools.append(.serverTool("openrouter:web_fetch", parameters: .object([
                    "max_uses": .number(4),
                    "max_content_tokens": .number(30_000)
                ])))
            } else {
                tools.append(readURLTool)
            }
        }

        tools.append(liveDataTool)
        tools.append(faultCodesTool)

        if settings.askUserEnabled {
            tools.append(askUserTool)
        }
        return tools
    }

    static let liveDataTool = ToolDefinition.function(
        name: "get_live_data",
        description: """
        Read the vehicle's live OBD-II sensor values right now (engine speed, coolant temperature, \
        fuel trims, O2 sensors, battery voltage and more). Call this before commenting on how the \
        engine is running, and again after the user changes something.
        """,
        parameters: .schema(
            properties: [
                "sensors": .arrayProperty(
                    "Optional list of sensor kinds to read. Omit for a curated set of the most useful sensors.",
                    items: .stringProperty("Sensor kind", enumValues: SensorKind.allCases.map(\.rawValue))
                )
            ]
        )
    )

    static let faultCodesTool = ToolDefinition.function(
        name: "get_fault_codes",
        description: """
        Read stored, pending and permanent diagnostic trouble codes (DTCs) from the ECU, with their \
        severity and on-device descriptions. Use this whenever the user mentions a warning light or \
        asks what is wrong with the car.
        """,
        parameters: .schema()
    )

    static let webSearchTool = ToolDefinition.function(
        name: "web_search",
        description: """
        Search the web for facts, recalls, technical service bulletins, torque specs, fluid capacities \
        and repair procedures. Prefer this over guessing. Cite the URLs you use.
        """,
        parameters: .schema(
            properties: [
                "query": .stringProperty("The search query, specific to this vehicle when possible."),
                "why": .stringProperty("Optional one-line reason for the search, used to rank results.")
            ],
            required: ["query"]
        )
    )

    static let videoSearchTool = ToolDefinition.function(
        name: "search_videos",
        description: """
        Find repair walkthrough videos (YouTube and Vimeo). Use when a visual procedure would help, \
        and include the best video links in your answer.
        """,
        parameters: .schema(
            properties: [
                "query": .stringProperty("What the video should show, e.g. 'replace P0420 catalytic converter 2015 Honda Civic'.")
            ],
            required: ["query"]
        )
    )

    static let partsSearchTool = ToolDefinition.function(
        name: "search_parts",
        description: """
        Find parts, tools and fluids for purchase with current listings and prices from major \
        retailers. Include the part names and links in your answer.
        """,
        parameters: .schema(
            properties: [
                "query": .stringProperty("The part or tool to find, including year/make/model and engine."),
                "category": .stringProperty(
                    "Optional category filter.",
                    enumValues: ["part", "tool", "fluid", "accessory"]
                )
            ],
            required: ["query"]
        )
    )

    static let readURLTool = ToolDefinition.function(
        name: "read_url",
        description: "Fetch a specific URL (repair guide, forum thread, listing, PDF page) and return its readable text.",
        parameters: .schema(
            properties: [
                "url": .stringProperty("The full http(s) URL to read.")
            ],
            required: ["url"]
        )
    )

    static let askUserTool = ToolDefinition.function(
        name: "ask_user",
        description: """
        Ask the user a multiple-choice question when missing information blocks a reliable answer \
        (symptoms, when it happens, recent work, tools available). Keep it to one focused question \
        and offer concrete options.
        """,
        parameters: .schema(
            properties: [
                "question": .stringProperty("The question to ask."),
                "header": .stringProperty("Short label for the question, 1-3 words."),
                "options": .arrayProperty(
                    "Two to five concrete answers.",
                    items: .schema(
                        properties: [
                            "label": .stringProperty("Answer text."),
                            "detail": .stringProperty("Optional clarification."),
                            "recommended": .booleanProperty("Mark the most likely answer.")
                        ],
                        required: ["label"]
                    )
                ),
                "allow_multiple": .booleanProperty("Allow selecting more than one option."),
                "allow_freeform": .booleanProperty("Allow the user to type an answer instead.")
            ],
            required: ["question", "options"]
        )
    )

    // MARK: Execution

    func execute(_ invocation: ToolInvocation) async -> ToolOutcome {
        switch invocation.name {
        case "get_live_data":
            return await liveData(sensors: invocation.arguments["sensors"]?.arrayValue?.compactMap(\.stringValue))
        case "get_fault_codes":
            return await faultCodes()
        case "web_search":
            return await searchOutcome(name: "web_search", args: invocation.arguments, scope: .web)
        case "search_videos":
            return await searchOutcome(name: "search_videos", args: invocation.arguments, scope: .videos)
        case "search_parts":
            return await searchOutcome(name: "search_parts", args: invocation.arguments, scope: .parts)
        case "read_url":
            return await readURL(args: invocation.arguments)
        case "ask_user":
            return await ask(args: invocation.arguments)
        default:
            return .error("Unknown tool \(invocation.name)", displayName: invocation.name, systemImage: "questionmark.circle")
        }
    }

    // MARK: OBD tools

    /// Waits briefly for the first poll cycle so tools never report an empty
    /// vehicle just because the session is still starting up.
    private func awaitLiveData() async {
        guard obd.isConnected, obd.readings.isEmpty else { return }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !obd.readings.isEmpty { return }
        }
    }

    private func liveData(sensors requested: [String]?) async -> ToolOutcome {
        await awaitLiveData()
        let converter = UnitConverter(system: settings.unitSystem)
        var kinds: [SensorKind] = []
        if let requested, !requested.isEmpty {
            kinds = requested.compactMap { raw in
                SensorKind(rawValue: raw) ?? SensorKind.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
            }
        } else {
            kinds = [.engineRPM, .vehicleSpeed, .coolantTemperature, .intakeAirTemperature, .engineLoad,
                     .throttlePosition, .batteryVoltage, .massAirFlow, .manifoldAbsolutePressure,
                     .shortTermFuelTrimBank1, .longTermFuelTrimBank1, .fuelLevel, .timingAdvance]
        }

        var payload: [String: JSONValue] = [
            "connected": .bool(obd.isConnected),
            "demo": .bool(obd.isDemo),
            "adapter": .string(obd.adapterInfo?.name ?? "none"),
            "vehicle": .string(garage.selectedVehicle?.fullName ?? "Unknown vehicle"),
            "units": .string(settings.unitSystem.title),
            "timestamp": .string(ISO8601DateFormatter().string(from: Date())),
            "faultCodeCount": .number(Double(obd.dtcs.count))
        ]

        var entries: [JSONValue] = []
        for kind in kinds {
            let definition = SensorCatalog.definition(for: kind)
            guard let reading = obd.reading(kind), reading.isValid else {
                entries.append(.object([
                    "kind": .string(kind.rawValue),
                    "name": .string(definition.name),
                    "supported": .bool(obd.supportedKinds.contains(kind)),
                    "value": .null
                ]))
                continue
            }
            let health = definition.health(for: reading.value)
            entries.append(.object([
                "kind": .string(kind.rawValue),
                "name": .string(definition.name),
                "value": .number(converter.value(reading.value, kind: definition.measure)),
                "unit": .string(converter.symbol(for: definition.measure)),
                "status": .string(health.label),
                "age": .number(max(0, Date().timeIntervalSince(reading.timestamp))),
                "supported": .bool(true)
            ]))
        }
        payload["sensors"] = .array(entries)

        if !obd.isConnected {
            payload["note"] = .string("No adapter is connected. Values may be empty or stale. The user can connect an adapter or start demo mode from the dashboard.")
        } else if obd.isDemo {
            payload["note"] = .string("These readings come from OBDiag's built-in demo simulator, not a real vehicle.")
        }
        return ToolOutcome(content: JSONValue.object(payload).jsonString,
                           displayName: "Live data", systemImage: "waveform.path.ecg")
    }

    private func faultCodes() async -> ToolOutcome {
        // A fresh code scan is cheap and keeps the answer honest.
        if obd.isConnected, obd.lastDTCScan == nil {
            await obd.refreshDTCs()
        } else if obd.isScanningDTCs {
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !obd.isScanningDTCs { break }
            }
        }

        func encode(_ codes: [DiagnosticTroubleCode]) -> JSONValue {
            .array(codes.map { code in
                .object([
                    "code": .string(code.code),
                    "title": .string(code.title),
                    "severity": .string(code.severity.rawValue),
                    "status": .string(code.status.rawValue),
                    "detail": .string(code.detail),
                    "possibleCauses": .array(code.possibleCauses.map { .string($0) }),
                    "recommendedActions": .array(code.recommendedActions.map { .string($0) })
                ])
            })
        }

        let payload: JSONValue = .object([
            "vehicle": .string(garage.selectedVehicle?.fullName ?? "Unknown vehicle"),
            "vin": .string(garage.selectedVehicle?.vin ?? "unknown"),
            "connected": .bool(obd.isConnected),
            "demo": .bool(obd.isDemo),
            "scannedAt": .string(obd.lastDTCScan.map { ISO8601DateFormatter().string(from: $0) } ?? "never"),
            "stored": encode(obd.storedCodes),
            "pending": encode(obd.pendingCodes),
            "permanent": encode(obd.permanentCodes),
            "scanInProgress": .bool(obd.isScanningDTCs),
            "note": .string("Stored codes are confirmed and usually turn on the MIL. Pending codes are unconfirmed. Permanent codes are emissions-related and cannot be cleared with a scan tool. If scannedAt is \"never\" and the vehicle is connected, the scan may still be starting.")
        ])
        return ToolOutcome(content: payload.jsonString,
                           displayName: "Fault codes", systemImage: "exclamationmark.triangle")
    }

    // MARK: Search tools

    private func searchOutcome(name: String, args: JSONValue, scope: SearchScope) async -> ToolOutcome {
        let displayName: String
        let icon: String
        switch scope {
        case .web: displayName = "Web search"; icon = "magnifyingglass"
        case .videos: displayName = "Video search"; icon = "play.rectangle"
        case .parts: displayName = "Parts search"; icon = "wrench.and.screwdriver"
        case .news: displayName = "News search"; icon = "newspaper"
        }

        guard let query = args["query"]?.stringValue, !query.isBlank else {
            return .error("The \(name) tool needs a `query`.", displayName: displayName, systemImage: icon)
        }

        var effectiveQuery = query
        if let category = args["category"]?.stringValue, !category.isBlank {
            effectiveQuery += " \(category)"
        }

        do {
            let results = try await search.search(effectiveQuery, scope: scope)
            let payload: JSONValue = .object([
                "query": .string(effectiveQuery),
                "backend": .string(search.lastBackendUsed ?? search.backendLabel),
                "results": .array(results.map { result in
                    .object([
                        "title": .string(result.title),
                        "url": .string(result.url),
                        "site": .string(result.host),
                        "snippet": .string(result.snippet.truncated(to: 500))
                    ])
                }),
                "note": .string("Cite the URLs you rely on using markdown links. If the results do not answer the question, try a more specific query.")
            ])
            return ToolOutcome(content: payload.jsonString, isError: false, displayName: displayName, systemImage: icon)
        } catch {
            return .error(error.localizedDescription, displayName: displayName, systemImage: icon)
        }
    }

    private func readURL(args: JSONValue) async -> ToolOutcome {
        guard let urlString = args["url"]?.stringValue, !urlString.isBlank else {
            return .error("The read_url tool needs a `url`.", displayName: "Read page", systemImage: "doc.text.magnifyingglass")
        }
        do {
            let page = try await search.readURL(urlString)
            let payload: JSONValue = .object([
                "url": .string(page.url),
                "title": .string(page.title),
                "content": .string(page.text),
                "note": .string("Extracted text may be truncated or noisy. Quote specifics accurately.")
            ])
            return ToolOutcome(content: payload.jsonString, displayName: "Read page", systemImage: "doc.text.magnifyingglass")
        } catch {
            return .error(error.localizedDescription, displayName: "Read page", systemImage: "doc.text.magnifyingglass")
        }
    }

    // MARK: Ask user

    private func ask(args: JSONValue) async -> ToolOutcome {
        let options = (args["options"]?.arrayValue ?? []).compactMap { item -> AskUserQuestion.Option? in
            guard let label = item["label"]?.stringValue else { return nil }
            return AskUserQuestion.Option(
                label: label,
                detail: item["detail"]?.stringValue,
                isRecommended: item["recommended"]?.boolValue ?? false
            )
        }
        let question = AskUserQuestion(
            question: args["question"]?.stringValue ?? "Could you tell me a bit more?",
            header: args["header"]?.stringValue,
            options: options,
            allowsMultiple: args["allow_multiple"]?.boolValue ?? false,
            allowsFreeform: args["allow_freeform"]?.boolValue ?? true
        )

        guard let askUser else {
            return .error("The user interface is not available to ask a question.", displayName: "Question", systemImage: "questionmark.bubble")
        }
        let answer = await askUser(question)
        let payload: JSONValue = .object([
            "question": .string(question.question),
            "answer": .string(answer),
            "answered": .bool(true),
            "note": .string("Continue using this answer. Do not repeat the question.")
        ])
        return ToolOutcome(content: payload.jsonString, displayName: "Asked user", systemImage: "questionmark.bubble")
    }
}
