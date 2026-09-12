import Foundation

/// A requestable OBD-II PID with its decoder.
struct PIDCommand: Identifiable {
    var pid: UInt8
    var kind: SensorKind
    /// Number of data bytes the PID returns (used for validation).
    var dataBytes: Int
    var decode: ([UInt8]) -> Double?
    var id: UInt8 { pid }
}

/// The full sensor catalog: metadata for the UI and decoders for the wire.
enum SensorCatalog {

    // MARK: Definitions
    static let definitions: [SensorKind: SensorDefinition] = {
        var map: [SensorKind: SensorDefinition] = [:]
        for definition in allDefinitions { map[definition.kind] = definition }
        return map
    }()

    static let allDefinitions: [SensorDefinition] = [
        // Engine
        SensorDefinition(kind: .engineRPM, name: "Engine speed", shortName: "RPM", measure: .rpm, group: .engine,
                         icon: "gauge.with.dots.needle.67percent", minimum: 0, maximum: 8000,
                         cautionBelow: nil, cautionAbove: 6200, criticalBelow: nil, criticalAbove: 7200),
        SensorDefinition(kind: .vehicleSpeed, name: "Vehicle speed", shortName: "Speed", measure: .speedKPH, group: .engine,
                         icon: "speedometer", minimum: 0, maximum: 260),
        SensorDefinition(kind: .engineLoad, name: "Calculated engine load", shortName: "Load", measure: .percent, group: .engine,
                         icon: "chart.bar.fill", minimum: 0, maximum: 100, cautionAbove: 92),
        SensorDefinition(kind: .absoluteLoad, name: "Absolute engine load", shortName: "Abs load", measure: .percent, group: .engine,
                         icon: "chart.bar.xaxis", minimum: 0, maximum: 100, cautionAbove: 95),
        SensorDefinition(kind: .throttlePosition, name: "Throttle position", shortName: "Throttle", measure: .percent, group: .engine,
                         icon: "pedal.accelerator", minimum: 0, maximum: 100),
        SensorDefinition(kind: .timingAdvance, name: "Timing advance", shortName: "Timing", measure: .angleDegrees, group: .engine,
                         icon: "clock.arrow.circlepath", minimum: -64, maximum: 64),
        SensorDefinition(kind: .runtimeSinceStart, name: "Run time since start", shortName: "Run time", measure: .durationSeconds, group: .engine,
                         icon: "timer", minimum: 0, maximum: 65_535),
        SensorDefinition(kind: .engineOilTemperature, name: "Engine oil temperature", shortName: "Oil temp", measure: .temperatureCelsius, group: .engine,
                         icon: "thermometer.variable", minimum: -40, maximum: 200, cautionAbove: 130, criticalAbove: 155),

        // Temperatures
        SensorDefinition(kind: .coolantTemperature, name: "Coolant temperature", shortName: "Coolant", measure: .temperatureCelsius, group: .temperatures,
                         icon: "thermometer.medium", minimum: -40, maximum: 150, cautionAbove: 106, criticalAbove: 118),
        SensorDefinition(kind: .intakeAirTemperature, name: "Intake air temperature", shortName: "Intake air", measure: .temperatureCelsius, group: .temperatures,
                         icon: "wind", minimum: -40, maximum: 120, cautionAbove: 65, criticalAbove: 90),
        SensorDefinition(kind: .ambientAirTemperature, name: "Ambient air temperature", shortName: "Ambient", measure: .temperatureCelsius, group: .temperatures,
                         icon: "sun.max", minimum: -40, maximum: 60),
        SensorDefinition(kind: .catalystTempBank1Sensor1, name: "Catalyst temp bank 1, sensor 1", shortName: "Cat B1S1", measure: .temperatureCelsius, group: .temperatures,
                         icon: "flame", minimum: 0, maximum: 1200, cautionAbove: 950),
        SensorDefinition(kind: .catalystTempBank1Sensor2, name: "Catalyst temp bank 1, sensor 2", shortName: "Cat B1S2", measure: .temperatureCelsius, group: .temperatures,
                         icon: "flame", minimum: 0, maximum: 1200, cautionAbove: 950),
        SensorDefinition(kind: .catalystTempBank2Sensor1, name: "Catalyst temp bank 2, sensor 1", shortName: "Cat B2S1", measure: .temperatureCelsius, group: .temperatures,
                         icon: "flame", minimum: 0, maximum: 1200, cautionAbove: 950),
        SensorDefinition(kind: .catalystTempBank2Sensor2, name: "Catalyst temp bank 2, sensor 2", shortName: "Cat B2S2", measure: .temperatureCelsius, group: .temperatures,
                         icon: "flame", minimum: 0, maximum: 1200, cautionAbove: 950),

        // Air & fuel
        SensorDefinition(kind: .manifoldAbsolutePressure, name: "Manifold absolute pressure", shortName: "MAP", measure: .pressureKPA, group: .airFuel,
                         icon: "barometer", minimum: 0, maximum: 255),
        SensorDefinition(kind: .boostPressure, name: "Boost pressure", shortName: "Boost", measure: .pressureKPA, group: .airFuel,
                         icon: "gauge.open.with.lines.needle.33percent", minimum: -100, maximum: 250),
        SensorDefinition(kind: .massAirFlow, name: "Mass air flow", shortName: "MAF", measure: .airFlowGramsPerSecond, group: .airFuel,
                         icon: "wind", minimum: 0, maximum: 400),
        SensorDefinition(kind: .fuelPressure, name: "Fuel pressure", shortName: "Fuel press", measure: .pressureKPA, group: .airFuel,
                         icon: "fuelpump", minimum: 0, maximum: 765),
        SensorDefinition(kind: .fuelRailGaugePressure, name: "Fuel rail pressure", shortName: "Rail press", measure: .pressureKPA, group: .airFuel,
                         icon: "fuelpump.fill", minimum: 0, maximum: 20_000),
        SensorDefinition(kind: .fuelLevel, name: "Fuel level", shortName: "Fuel", measure: .percent, group: .airFuel,
                         icon: "fuelpump", minimum: 0, maximum: 100, cautionBelow: 10),
        SensorDefinition(kind: .barometricPressure, name: "Barometric pressure", shortName: "Baro", measure: .pressureKPA, group: .airFuel,
                         icon: "barometer", minimum: 60, maximum: 110),
        SensorDefinition(kind: .commandedEquivalenceRatio, name: "Commanded equivalence ratio", shortName: "Equiv ratio", measure: .lambda, group: .airFuel,
                         icon: "atom", minimum: 0, maximum: 2, cautionBelow: 0.75, cautionAbove: 1.25),
        SensorDefinition(kind: .ethanolFuelPercent, name: "Ethanol fuel percentage", shortName: "Ethanol", measure: .percent, group: .airFuel,
                         icon: "drop.fill", minimum: 0, maximum: 100),
        SensorDefinition(kind: .fuelType, name: "Fuel type", shortName: "Fuel type", measure: .text, group: .airFuel,
                         icon: "fuelpump.circle", minimum: 0, maximum: 23),

        // Fuel trims
        SensorDefinition(kind: .shortTermFuelTrimBank1, name: "Short term fuel trim, bank 1", shortName: "STFT B1", measure: .percent, group: .fuelTrims,
                         icon: "arrow.left.arrow.right", minimum: -50, maximum: 50, cautionBelow: -15, cautionAbove: 15, criticalBelow: -30, criticalAbove: 30),
        SensorDefinition(kind: .longTermFuelTrimBank1, name: "Long term fuel trim, bank 1", shortName: "LTFT B1", measure: .percent, group: .fuelTrims,
                         icon: "arrow.left.arrow.right.circle", minimum: -50, maximum: 50, cautionBelow: -12, cautionAbove: 12, criticalBelow: -25, criticalAbove: 25),
        SensorDefinition(kind: .shortTermFuelTrimBank2, name: "Short term fuel trim, bank 2", shortName: "STFT B2", measure: .percent, group: .fuelTrims,
                         icon: "arrow.left.arrow.right", minimum: -50, maximum: 50, cautionBelow: -15, cautionAbove: 15, criticalBelow: -30, criticalAbove: 30),
        SensorDefinition(kind: .longTermFuelTrimBank2, name: "Long term fuel trim, bank 2", shortName: "LTFT B2", measure: .percent, group: .fuelTrims,
                         icon: "arrow.left.arrow.right.circle", minimum: -50, maximum: 50, cautionBelow: -12, cautionAbove: 12, criticalBelow: -25, criticalAbove: 25),

        // O2 sensors
        SensorDefinition(kind: .o2Bank1Sensor1, name: "O₂ sensor, bank 1 sensor 1", shortName: "O₂ B1S1", measure: .voltage, group: .o2Sensors,
                         icon: "aqi.low", minimum: 0, maximum: 1.3),
        SensorDefinition(kind: .o2Bank1Sensor2, name: "O₂ sensor, bank 1 sensor 2", shortName: "O₂ B1S2", measure: .voltage, group: .o2Sensors,
                         icon: "aqi.low", minimum: 0, maximum: 1.3),
        SensorDefinition(kind: .o2Bank2Sensor1, name: "O₂ sensor, bank 2 sensor 1", shortName: "O₂ B2S1", measure: .voltage, group: .o2Sensors,
                         icon: "aqi.low", minimum: 0, maximum: 1.3),
        SensorDefinition(kind: .o2Bank2Sensor2, name: "O₂ sensor, bank 2 sensor 2", shortName: "O₂ B2S2", measure: .voltage, group: .o2Sensors,
                         icon: "aqi.low", minimum: 0, maximum: 1.3),

        // Electrical
        SensorDefinition(kind: .batteryVoltage, name: "Control module voltage", shortName: "Battery", measure: .voltage, group: .electrical,
                         icon: "bolt.fill", minimum: 8, maximum: 16, cautionBelow: 12.4, cautionAbove: 15.0, criticalBelow: 11.6),

        // Emissions
        SensorDefinition(kind: .commandedEGR, name: "Commanded EGR", shortName: "EGR cmd", measure: .percent, group: .emissions,
                         icon: "arrow.triangle.2.circlepath", minimum: 0, maximum: 100),
        SensorDefinition(kind: .egrError, name: "EGR error", shortName: "EGR err", measure: .percent, group: .emissions,
                         icon: "exclamationmark.arrow.triangle.2.circlepath", minimum: -50, maximum: 50, cautionBelow: -25, cautionAbove: 25),
        SensorDefinition(kind: .evapPurge, name: "Evaporative purge", shortName: "EVAP", measure: .percent, group: .emissions,
                         icon: "leaf", minimum: 0, maximum: 100),

        // Counters
        SensorDefinition(kind: .distanceWithMILOn, name: "Distance driven with MIL on", shortName: "MIL distance", measure: .distanceKM, group: .counters,
                         icon: "exclamationmark.triangle", minimum: 0, maximum: 65_535),
        SensorDefinition(kind: .distanceSinceCodesCleared, name: "Distance since codes cleared", shortName: "Since clear", measure: .distanceKM, group: .counters,
                         icon: "arrow.counterclockwise", minimum: 0, maximum: 65_535),
        SensorDefinition(kind: .timeSinceCodesCleared, name: "Time since codes cleared", shortName: "Clear time", measure: .durationSeconds, group: .counters,
                         icon: "clock.arrow.circlepath", minimum: 0, maximum: 65_535),
        SensorDefinition(kind: .warmupsSinceCodesCleared, name: "Warm-ups since codes cleared", shortName: "Warm-ups", measure: .count, group: .counters,
                         icon: "sun.horizon", minimum: 0, maximum: 255)
    ]

    static func definition(for kind: SensorKind) -> SensorDefinition {
        definitions[kind] ?? SensorDefinition(
            kind: kind, name: kind.rawValue.humanizedIdentifier, shortName: kind.rawValue, measure: .count,
            group: .engine, icon: "waveform.path.ecg", minimum: 0, maximum: 100
        )
    }

    // MARK: Commands
    static let commands: [PIDCommand] = [
        PIDCommand(pid: 0x0C, kind: .engineRPM, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 4 : nil
        },
        PIDCommand(pid: 0x0D, kind: .vehicleSpeed, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) : nil
        },
        PIDCommand(pid: 0x04, kind: .engineLoad, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) * 100 / 255 : nil
        },
        PIDCommand(pid: 0x43, kind: .absoluteLoad, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) * 100 / 255 : nil
        },
        PIDCommand(pid: 0x11, kind: .throttlePosition, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) * 100 / 255 : nil
        },
        PIDCommand(pid: 0x0E, kind: .timingAdvance, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) / 2 - 64 : nil
        },
        PIDCommand(pid: 0x1F, kind: .runtimeSinceStart, dataBytes: 2) { d in
            d.count >= 2 ? Double(Int(d[0]) * 256 + Int(d[1])) : nil
        },
        PIDCommand(pid: 0x5C, kind: .engineOilTemperature, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) - 40 : nil
        },
        PIDCommand(pid: 0x05, kind: .coolantTemperature, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) - 40 : nil
        },
        PIDCommand(pid: 0x0F, kind: .intakeAirTemperature, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) - 40 : nil
        },
        PIDCommand(pid: 0x46, kind: .ambientAirTemperature, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) - 40 : nil
        },
        PIDCommand(pid: 0x3C, kind: .catalystTempBank1Sensor1, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 10 - 40 : nil
        },
        PIDCommand(pid: 0x3D, kind: .catalystTempBank1Sensor2, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 10 - 40 : nil
        },
        PIDCommand(pid: 0x3E, kind: .catalystTempBank2Sensor1, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 10 - 40 : nil
        },
        PIDCommand(pid: 0x3F, kind: .catalystTempBank2Sensor2, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 10 - 40 : nil
        },
        PIDCommand(pid: 0x0B, kind: .manifoldAbsolutePressure, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) : nil
        },
        PIDCommand(pid: 0x10, kind: .massAirFlow, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 100 : nil
        },
        PIDCommand(pid: 0x0A, kind: .fuelPressure, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) * 3 : nil
        },
        PIDCommand(pid: 0x23, kind: .fuelRailGaugePressure, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) * 10 : nil
        },
        PIDCommand(pid: 0x2F, kind: .fuelLevel, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) * 100 / 255 : nil
        },
        PIDCommand(pid: 0x33, kind: .barometricPressure, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) : nil
        },
        PIDCommand(pid: 0x44, kind: .commandedEquivalenceRatio, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 32768 : nil
        },
        PIDCommand(pid: 0x52, kind: .ethanolFuelPercent, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) * 100 / 255 : nil
        },
        PIDCommand(pid: 0x51, kind: .fuelType, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) : nil
        },
        PIDCommand(pid: 0x06, kind: .shortTermFuelTrimBank1, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) / 1.28 - 100 : nil
        },
        PIDCommand(pid: 0x07, kind: .longTermFuelTrimBank1, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) / 1.28 - 100 : nil
        },
        PIDCommand(pid: 0x08, kind: .shortTermFuelTrimBank2, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) / 1.28 - 100 : nil
        },
        PIDCommand(pid: 0x09, kind: .longTermFuelTrimBank2, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) / 1.28 - 100 : nil
        },
        PIDCommand(pid: 0x14, kind: .o2Bank1Sensor1, dataBytes: 2) { d in
            d.count >= 1 ? Double(d[0]) / 200 : nil
        },
        PIDCommand(pid: 0x15, kind: .o2Bank1Sensor2, dataBytes: 2) { d in
            d.count >= 1 ? Double(d[0]) / 200 : nil
        },
        PIDCommand(pid: 0x18, kind: .o2Bank2Sensor1, dataBytes: 2) { d in
            d.count >= 1 ? Double(d[0]) / 200 : nil
        },
        PIDCommand(pid: 0x19, kind: .o2Bank2Sensor2, dataBytes: 2) { d in
            d.count >= 1 ? Double(d[0]) / 200 : nil
        },
        PIDCommand(pid: 0x42, kind: .batteryVoltage, dataBytes: 2) { d in
            d.count >= 2 ? (Double(d[0]) * 256 + Double(d[1])) / 1000 : nil
        },
        PIDCommand(pid: 0x2C, kind: .commandedEGR, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) * 100 / 255 : nil
        },
        PIDCommand(pid: 0x2D, kind: .egrError, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) / 1.28 - 100 : nil
        },
        PIDCommand(pid: 0x2E, kind: .evapPurge, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) * 100 / 255 : nil
        },
        PIDCommand(pid: 0x21, kind: .distanceWithMILOn, dataBytes: 2) { d in
            d.count >= 2 ? Double(Int(d[0]) * 256 + Int(d[1])) : nil
        },
        PIDCommand(pid: 0x31, kind: .distanceSinceCodesCleared, dataBytes: 2) { d in
            d.count >= 2 ? Double(Int(d[0]) * 256 + Int(d[1])) : nil
        },
        PIDCommand(pid: 0x4E, kind: .timeSinceCodesCleared, dataBytes: 2) { d in
            d.count >= 2 ? Double(Int(d[0]) * 256 + Int(d[1])) * 60 : nil
        },
        PIDCommand(pid: 0x30, kind: .warmupsSinceCodesCleared, dataBytes: 1) { d in
            d.count >= 1 ? Double(d[0]) : nil
        }
    ]

    static let commandsByKind: [SensorKind: PIDCommand] = {
        Dictionary(uniqueKeysWithValues: commands.map { ($0.kind, $0) })
    }()

    static func command(for kind: SensorKind) -> PIDCommand? { commandsByKind[kind] }

    /// Order used when polling: cheap, high-interest sensors first.
    static let pollingOrder: [SensorKind] = [
        .engineRPM, .vehicleSpeed, .coolantTemperature, .engineLoad, .throttlePosition,
        .intakeAirTemperature, .batteryVoltage, .massAirFlow, .manifoldAbsolutePressure,
        .shortTermFuelTrimBank1, .longTermFuelTrimBank1,
        .shortTermFuelTrimBank2, .longTermFuelTrimBank2,
        .o2Bank1Sensor1, .o2Bank1Sensor2, .o2Bank2Sensor1, .o2Bank2Sensor2,
        .fuelLevel, .fuelPressure, .fuelRailGaugePressure,
        .timingAdvance, .barometricPressure, .commandedEquivalenceRatio, .ethanolFuelPercent,
        .ambientAirTemperature, .engineOilTemperature,
        .catalystTempBank1Sensor1, .catalystTempBank1Sensor2,
        .catalystTempBank2Sensor1, .catalystTempBank2Sensor2,
        .commandedEGR, .egrError, .evapPurge,
        .runtimeSinceStart, .distanceWithMILOn, .distanceSinceCodesCleared,
        .timeSinceCodesCleared, .warmupsSinceCodesCleared, .absoluteLoad, .fuelType
    ]

    /// Human-readable fuel type from PID 0x51.
    static func fuelTypeName(_ raw: UInt8) -> String {
        switch raw {
        case 0: return "Not available"
        case 1: return "Gasoline"
        case 2: return "Methanol"
        case 3: return "Ethanol"
        case 4: return "Diesel"
        case 5: return "LPG"
        case 6: return "CNG"
        case 7: return "Propane"
        case 8: return "Electric"
        case 9: return "Bifuel (gasoline)"
        case 10: return "Bifuel (methanol)"
        case 11: return "Bifuel (ethanol)"
        case 12: return "Bifuel (LPG)"
        case 13: return "Bifuel (CNG)"
        case 14: return "Bifuel (propane)"
        case 15: return "Bifuel (electric)"
        case 16: return "Hybrid gasoline"
        case 17: return "Hybrid ethanol"
        case 18: return "Hybrid diesel"
        case 19: return "Hybrid electric"
        case 20: return "Hybrid mixed"
        case 21: return "Hybrid regenerative"
        case 22: return "Bifuel (diesel)"
        case 23: return "Bifuel (electric)"
        default: return "Unknown (\(raw))"
        }
    }

    /// Decodes a supported-PID bitmask (e.g. response to 01 00) into PID numbers.
    static func supportedPIDs(fromBytes bytes: [UInt8], base: UInt8) -> Set<UInt8> {
        guard bytes.count >= 4 else { return [] }
        var result: Set<UInt8> = []
        for byteIndex in 0..<4 {
            let value = bytes[byteIndex]
            for bit in 0..<8 where value & (0x80 >> UInt8(bit)) != 0 {
                result.insert(base + UInt8(byteIndex * 8 + bit + 1))
            }
        }
        return result
    }
}

/// Emissions readiness snapshot from PID 01 01.
struct MonitorStatus: Equatable, Sendable {
    var milOn: Bool
    var dtcCount: Int
    var misfireMonitorComplete: Bool
    var fuelSystemMonitorComplete: Bool
    var componentsMonitorComplete: Bool

    static func decode(_ bytes: [UInt8]) -> MonitorStatus? {
        guard bytes.count >= 3 else { return nil }
        let a = bytes[0], c = bytes[2]
        return MonitorStatus(
            milOn: a & 0x80 != 0,
            dtcCount: Int(a & 0x7F),
            misfireMonitorComplete: c & 0x80 != 0,
            fuelSystemMonitorComplete: c & 0x40 != 0,
            componentsMonitorComplete: c & 0x20 != 0
        )
    }
}
