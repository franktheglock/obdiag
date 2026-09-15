import SwiftUI
import Charts

/// Adaptive grid of live sensor tiles.
struct SensorsGrid: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let kinds: [SensorKind]
    var onSelect: (SensorKind) -> Void

    private var columns: [GridItem] {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 300 : 158
        return [GridItem(.adaptive(minimum: minimum, maximum: 400), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(kinds, id: \.self) { kind in
                SensorTile(
                    kind: kind,
                    reading: env.obd.reading(kind),
                    history: env.obd.historyValues(kind),
                    unitSystem: env.settings.unitSystem,
                    health: env.obd.health(for: kind)
                ) {
                    Haptics.tap()
                    onSelect(kind)
                }
            }
        }
    }
}

/// A single live value, presented like a Health metric: label, large tabular
/// reading, unit, and a short history trace.
struct SensorTile: View {
    let kind: SensorKind
    let reading: SensorReading?
    let history: [Double]
    let unitSystem: UnitSystem
    let health: ReadingHealth
    var onSelect: () -> Void

    private var definition: SensorDefinition { SensorCatalog.definition(for: kind) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: definition.icon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(health == .inactive ? Palette.textTertiary : health.color)
                    Text(definition.shortName)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(valueText)
                        .obMono(27, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: reading?.value)
                    Text(unitText)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }

                if history.count > 2 {
                    Sparkline(values: history, color: health == .inactive ? Palette.textTertiary : health.color)
                        .frame(height: 22)
                } else {
                    Color.clear.frame(height: 22)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
        .accessibilityLabel("\(definition.name): \(valueText) \(unitText), \(health.label)")
    }

    private var valueText: String {
        guard let reading, reading.isValid else { return "—" }
        if definition.measure == .text {
            return SensorCatalog.fuelTypeName(UInt8(clamping: Int(reading.value)))
        }
        let converter = UnitConverter(system: unitSystem)
        return converter.formatted(reading.value, kind: definition.measure)
    }

    private var unitText: String {
        guard reading?.isValid == true, definition.measure != .text else { return "" }
        return UnitConverter(system: unitSystem).symbol(for: definition.measure)
    }
}

/// Tiny inline history line.
struct Sparkline: View {
    let values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? 1
            let range = max(maximum - minimum, 0.0001)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geo.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat((value - minimum) / range))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - All sensors

struct AllSensorsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selected: SensorKind?
    @State private var search = ""

    private var grouped: [(SensorGroup, [SensorKind])] {
        let available = SensorCatalog.pollingOrder.filter { env.obd.supportedKinds.contains($0) }
        let filtered = search.isBlank ? available : available.filter {
            SensorCatalog.definition(for: $0).name.localizedCaseInsensitiveContains(search)
        }
        return SensorGroup.allCases.compactMap { group in
            let kinds = filtered.filter { SensorCatalog.definition(for: $0).group == group }
            return kinds.isEmpty ? nil : (group, kinds)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if grouped.isEmpty {
                    EmptyStateView(
                        systemImage: "gauge.with.dots.needle.67percent",
                        title: env.obd.isConnected ? "No sensors reported" : "Not connected",
                        message: env.obd.isConnected
                            ? "This vehicle didn't report any supported PIDs in the ranges OBDiag polls."
                            : "Connect an adapter to see the full list of live values."
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(grouped, id: \.0) { group, kinds in
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: group.title, subtitle: "\(kinds.count) supported") {
                                Image(systemName: group.icon)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                                    SensorRow(kind: kind) { selected = kind }
                                    if index < kinds.count - 1 {
                                        Divider().overlay(Palette.stroke)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .panel()
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("All sensors")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search sensors")
        .sheet(item: $selected) { kind in
            SensorDetailView(kind: kind)
        }
    }
}

struct SensorRow: View {
    @Environment(AppEnvironment.self) private var env
    let kind: SensorKind
    var onSelect: () -> Void

    private var definition: SensorDefinition { SensorCatalog.definition(for: kind) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: definition.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(health == .inactive ? Palette.textTertiary : health.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.name)
                        .font(.obCallout)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(health.label)
                        .font(.obMicro)
                        .foregroundStyle(health == .inactive ? Palette.textTertiary : health.color)
                }
                Spacer(minLength: 6)
                Text(valueText)
                    .obMono(16, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                    .fixedSize()
                Text(unitText)
                    .font(.obMicro)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize()
                    .frame(minWidth: 34, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var health: ReadingHealth { env.obd.health(for: kind) }

    private var valueText: String {
        guard let reading = env.obd.reading(kind), reading.isValid else { return "—" }
        if definition.measure == .text {
            return SensorCatalog.fuelTypeName(UInt8(clamping: Int(reading.value)))
        }
        let converter = UnitConverter(system: env.settings.unitSystem)
        return converter.formatted(reading.value, kind: definition.measure)
    }

    private var unitText: String {
        guard env.obd.reading(kind)?.isValid == true, definition.measure != .text else { return "" }
        return UnitConverter(system: env.settings.unitSystem).symbol(for: definition.measure)
    }
}

// MARK: - Detail

struct SensorDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let kind: SensorKind

    private var definition: SensorDefinition { SensorCatalog.definition(for: kind) }
    private var reading: SensorReading? { env.obd.reading(kind) }
    private var health: ReadingHealth { env.obd.health(for: kind) }
    private var converter: UnitConverter { UnitConverter(system: env.settings.unitSystem) }

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    if !history.isEmpty {
                        chart
                    }
                    rangeCard
                    knowledgeCard
                    if health == .critical || health == .warning {
                        adviceCard
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
            .navigationTitle(definition.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var history: [Double] {
        env.obd.historyValues(kind).map { converter.value($0, kind: definition.measure) }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(currentValueText)
                    .obMono(44, weight: .bold)
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                Text(converter.symbol(for: definition.measure))
                    .font(.obTitle2)
                    .foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: 8) {
                SeverityBadge(severity: healthSeverity)
                GlassChip(text: definition.group.title, systemImage: definition.group.icon, tint: Palette.textSecondary)
                if let updated = reading?.timestamp {
                    GlassChip(text: Format.relative(updated), systemImage: "clock", tint: Palette.textTertiary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var healthSeverity: Severity {
        switch health {
        case .normal: return .low
        case .caution: return .moderate
        case .warning: return .high
        case .critical: return .critical
        case .inactive: return .info
        }
    }

    private var currentValueText: String {
        guard let reading, reading.isValid else { return "—" }
        return converter.formatted(reading.value, kind: definition.measure)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(history.count) samples")
                .font(.obCaption)
                .foregroundStyle(Palette.textTertiary)
            // The fill is anchored to the visible axis floor, not to zero:
            // the y domain is clamped to the recent readings, so a fill down
            // to zero would draw far below the plot area.
            let domain = chartDomain
            let color = health == .inactive ? Palette.accent : health.color
            Chart {
                ForEach(Array(history.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("Sample", index),
                        yStart: .value("Floor", domain.lowerBound),
                        yEnd: .value(definition.shortName, value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(colors: [color.opacity(0.25), .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    LineMark(
                        x: .value("Sample", index),
                        y: .value(definition.shortName, value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(color)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .frame(height: 170)
            .clipped()
        }
        .padding(14)
        .panel()
    }

    private var chartDomain: ClosedRange<Double> {
        let values = history.isEmpty ? [0.0, 1.0] : history
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let padding = max((maximum - minimum) * 0.15, 0.5)
        return (minimum - padding)...(maximum + padding)
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Healthy range")
                .font(.obHeadline)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: 10) {
                rangeValue("Typical", definition.minimum, color: Palette.success)
                rangeValue("Watch above", definition.cautionAbove, color: Palette.amber)
                rangeValue("Critical above", definition.criticalAbove, color: Palette.danger)
            }
        }
        .padding(14)
        .panel()
    }

    private func rangeValue(_ label: String, _ value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
            Text(value.map { converter.formatted($0, kind: definition.measure) + " " + converter.symbol(for: definition.measure) } ?? "—")
                .obMono(15, weight: .semibold)
                .foregroundStyle(value == nil ? Palette.textTertiary : color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var knowledgeCard: some View {
        let knowledge = SensorKnowledge.text(for: kind)
        return VStack(alignment: .leading, spacing: 8) {
            Text("What this tells you")
                .font(.obHeadline)
                .foregroundStyle(Palette.textPrimary)
            Text(knowledge.what)
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
            if let watch = knowledge.watch {
                Text(watch)
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .panel()
    }

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask the assistant about this", systemImage: "bubble.left.and.text.bubble.right")
                .font(.obHeadline)
                .foregroundStyle(Palette.textPrimary)
            Text("This reading is outside the healthy range. The AI assistant can relate it to your fault codes and tell you what to check.")
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(14)
        .panel(tint: Palette.amber.opacity(0.12))
    }
}

/// Short plain-language explanations for the sensor detail view.
enum SensorKnowledge {
    struct Text {
        var what: String
        var watch: String?
    }

    static func text(for kind: SensorKind) -> Text {
        if let entry = table[kind] { return entry }
        return Text(what: "This value is reported directly by the engine control module over OBD-II.", watch: nil)
    }

    private static let table: [SensorKind: Text] = [
        .engineRPM: .init(what: "How fast the crankshaft is spinning. Idle is usually 600–900 rpm; cruising at 60 mph sits around 1,800–2,500 rpm depending on gearing.", watch: "Rough or surging idle often shows up here first."),
        .vehicleSpeed: .init(what: "The speed the ECU calculates from the transmission or wheel sensors.", watch: "If this reads zero while driving, the speed sensor or ABS module is implicated."),
        .coolantTemperature: .init(what: "Engine coolant temperature once warmed up. Normal operating range is roughly 88–104 °C (190–220 °F).", watch: "Above 110 °C (230 °F) is overheating — stop driving and let it cool."),
        .intakeAirTemperature: .init(what: "Temperature of the air entering the engine. It should sit close to ambient when moving.", watch: "Very high intake temps reduce power and can indicate heat soak or a failing sensor."),
        .engineLoad: .init(what: "How hard the engine is working as a percentage of its maximum available output at current rpm.", watch: "High load at idle suggests drag, a restriction, or a sensor issue."),
        .throttlePosition: .init(what: "How far the throttle plate is open. Roughly 10–15% at idle, rising smoothly toward 100%.", watch: "Jumping or non-repeating values point to a worn sensor or carbon buildup."),
        .batteryVoltage: .init(what: "System voltage as seen by the ECU. With the engine running you should see 13.5–14.6 V.", watch: "Below 12.4 V at idle often means a failing alternator or battery."),
        .massAirFlow: .init(what: "Grams of air per second entering the engine. Idle is around 2–5 g/s; wide-open throttle can exceed 100 g/s.", watch: "A dirty MAF under-reports airflow and causes lean codes such as P0171."),
        .manifoldAbsolutePressure: .init(what: "Absolute pressure in the intake manifold. At idle on a naturally aspirated engine it's low (around 30–40 kPa); it rises toward barometric as the throttle opens.", watch: "On turbo cars, MAP minus barometric gives boost."),
        .boostPressure: .init(what: "Pressure above atmospheric produced by the turbo or supercharger, derived from MAP minus barometric pressure.", watch: "Sagging boost under load points to a boost leak or a stuck wastegate."),
        .shortTermFuelTrimBank1: .init(what: "Real-time fuel correction. Positive means the ECU is adding fuel (lean), negative means it is pulling fuel (rich). Normal is within ±10%.", watch: "Sustained trims beyond ±15% usually set a P0171/P0172 fault."),
        .longTermFuelTrimBank1: .init(what: "The learned fuel correction the ECU carries between drive cycles. Normal is within ±10%.", watch: "Large positive values suggest a vacuum leak, weak fuel delivery or a dirty MAF."),
        .o2Bank1Sensor1: .init(what: "Upstream oxygen sensor voltage, switching rapidly between about 0.1 V (lean) and 0.9 V (rich) once in closed loop.", watch: "A flat or lazy signal means the sensor (or its heater) is failing."),
        .fuelLevel: .init(what: "Fuel tank level reported by the sender.", watch: "Running below 10% can expose the pump and cause misfires on some cars."),
        .timingAdvance: .init(what: "Degrees of ignition advance before top dead center. Typically 10–35° under light load, less under heavy load.", watch: "Large negative values during knock events can indicate bad fuel or a failing knock sensor."),
        .catalystTempBank1Sensor1: .init(what: "Exhaust temperature entering the catalytic converter. Normal is roughly 400–800 °C under load.", watch: "Above 950 °C can melt the converter — often caused by misfires or a rich condition."),
        .fuelRailGaugePressure: .init(what: "Fuel rail pressure relative to atmosphere, reported by diesel and some direct-injection systems.", watch: "Low pressure under load causes lean codes and power loss."),
        .commandedEquivalenceRatio: .init(what: "The air/fuel ratio the ECU is targeting, where 1.0 is stoichiometric (14.7:1 for gasoline).", watch: "Values far from 1.0 during cruise suggest a fuel delivery problem."),
        .ethanolFuelPercent: .init(what: "Ethanol content of the fuel, as sensed by the flex-fuel sensor.", watch: "A sudden change without refueling points to a sensor fault.")
    ]
}
