import Foundation

/// On-device fault-code knowledge base. Provides instant, offline descriptions
/// for the most common codes; the AI assistant fills the gaps with
/// vehicle-specific detail and live sources.
enum DTCKnowledge {

    struct Entry {
        var title: String
        var detail: String
        var severity: Severity
        var causes: [String]
        var symptoms: [String]
        var actions: [String]
    }

    // MARK: Public API

    static func makeCode(_ raw: String, status: DTCStatus) -> DiagnosticTroubleCode {
        let code = raw.uppercased().trimmed
        let entry = database[code] ?? generic(for: code)
        return DiagnosticTroubleCode(
            code: code,
            status: status,
            title: entry.title,
            detail: entry.detail,
            severity: entry.severity,
            possibleCauses: entry.causes,
            symptoms: entry.symptoms,
            recommendedActions: entry.actions,
            isManufacturerSpecific: isManufacturerSpecific(code),
            freezeFrame: []
        )
    }

    /// Parses DTC payloads from mode 03 (stored), 07 (pending) or 0A (permanent).
    /// SAE J2012 layout: byte 1 = system (bits 7-6), second character (bits 5-4),
    /// third character (bits 3-0); byte 2 = fourth and fifth characters.
    static func codes(fromPayload bytes: [UInt8]) -> [String] {
        var codes: [String] = []
        var index = 0
        while index + 1 < bytes.count {
            let first = bytes[index]
            let second = bytes[index + 1]
            index += 2
            guard first != 0 || second != 0 else { continue }
            let system: String
            switch first >> 6 {
            case 0: system = "P"
            case 1: system = "C"
            case 2: system = "B"
            case 3: system = "U"
            default: continue
            }
            let secondCharacter = (first >> 4) & 0x03
            let thirdCharacter = first & 0x0F
            let code = String(format: "%@%X%X%02X", system, secondCharacter, thirdCharacter, second)
            codes.append(code)
        }
        return codes
    }

    /// Family description for codes not in the database.
    static func generic(for code: String) -> Entry {
        let upper = code.uppercased()
        let prefix = upper.count >= 3 ? String(upper.prefix(3)) : upper
        let system = DTCSystem.from(code: upper)
        var title = "\(system.title) code \(upper)"
        var causes: [String] = []
        var actions: [String] = []

        switch prefix {
        case "P00", "P01", "P02":
            title = "Fuel & air metering fault (\(upper))"
            causes = ["Vacuum or intake leak", "Faulty mass air flow or oxygen sensor", "Fuel pressure out of spec"]
            actions = ["Check for intake leaks and cracked hoses", "Verify fuel pressure and sensor live data", "Inspect wiring to the affected sensor"]
        case "P03":
            title = "Ignition system fault (\(upper))"
            causes = ["Worn spark plugs or coils", "Faulty crank or cam sensor", "Wiring or connector corrosion"]
            actions = ["Inspect spark plugs and coil packs", "Check crank/cam sensor signals", "Look for chafed ignition wiring"]
        case "P04":
            title = "Emissions control fault (\(upper))"
            causes = ["Faulty EGR valve or clogged passages", "EVAP leak (loose or failed gas cap)", "Failed purge or vent solenoid"]
            actions = ["Inspect EVAP hoses and the fuel cap seal", "Test the EGR valve and clean passages", "Run an EVAP smoke test"]
        case "P05":
            title = "Speed & idle control fault (\(upper))"
            causes = ["Faulty vehicle speed sensor", "Carbon buildup in the throttle body", "Idle air control valve issue"]
            actions = ["Verify speed sensor signal", "Clean the throttle body and idle air passages", "Perform an idle relearn if required"]
        case "P06":
            title = "Computer & output circuit fault (\(upper))"
            causes = ["Failing sensor or actuator on the circuit", "Short or open in the harness", "Low system voltage"]
            actions = ["Check battery voltage and grounds", "Inspect the affected circuit for shorts", "Verify powers and grounds at the module"]
        case "P07", "P08", "P09":
            title = "Transmission fault (\(upper))"
            causes = ["Low or degraded transmission fluid", "Faulty solenoid or speed sensor", "Internal mechanical wear"]
            actions = ["Check fluid level and condition", "Scan transmission control module for companion codes", "Avoid hard driving until diagnosed"]
        case "U0", "U1", "U2":
            title = "Network communication fault (\(upper))"
            causes = ["CAN bus wiring fault", "Control module power or ground issue", "Failing module on the network"]
            actions = ["Check for other modules reporting offline", "Inspect CAN wiring and connectors", "Verify battery voltage is stable"]
        case "C0", "C1", "C2":
            title = "Chassis fault (\(upper))"
            causes = ["Wheel speed sensor or tone ring damage", "ABS module wiring fault", "Steering angle sensor calibration"]
            actions = ["Inspect wheel speed sensors and tone rings", "Check ABS harness routing", "Re-calibrate affected sensors"]
        case "B0", "B1", "B2":
            title = "Body fault (\(upper))"
            causes = ["Body control module circuit fault", "Failed switch or actuator", "Water intrusion in a connector"]
            actions = ["Check fuses for the affected system", "Inspect connectors for corrosion", "Test the switch or actuator directly"]
        default:
            causes = ["Intermittent electrical fault", "Worn component", "Wiring or connector issue"]
            actions = ["Record freeze-frame data before clearing", "Ask the AI assistant for this exact code", "Inspect related wiring and connectors"]
        }

        return Entry(
            title: title,
            detail: "This code is not in the on-device library. Ask the AI assistant to explain \(upper) for your specific vehicle and to find the factory diagnostic procedure.",
            severity: isManufacturerSpecific(upper) ? .moderate : .low,
            causes: causes,
            symptoms: [],
            actions: actions
        )
    }

    private static func isManufacturerSpecific(_ code: String) -> Bool {
        let upper = code.uppercased()
        guard upper.count >= 2 else { return false }
        let second = upper[upper.index(after: upper.startIndex)]
        return second == "1" || second == "2" || second == "3"
    }

    // MARK: Database

    private static func e(
        _ title: String, _ detail: String, _ severity: Severity,
        _ causes: [String], _ symptoms: [String], _ actions: [String]
    ) -> Entry {
        Entry(title: title, detail: detail, severity: severity, causes: causes, symptoms: symptoms, actions: actions)
    }

    /// Shorthand for codes where only causes are known; the assistant fills in the rest.
    private static func e(
        _ title: String, _ detail: String, _ severity: Severity,
        _ causes: [String]
    ) -> Entry {
        Entry(title: title, detail: detail, severity: severity, causes: causes, symptoms: [], actions: [])
    }

    /// Shorthand for codes with causes and symptoms but no catalogued next steps.
    private static func e(
        _ title: String, _ detail: String, _ severity: Severity,
        _ causes: [String], _ symptoms: [String]
    ) -> Entry {
        Entry(title: title, detail: detail, severity: severity, causes: causes, symptoms: symptoms, actions: [])
    }

    static let database: [String: Entry] = [
        // MARK: Camshaft / crankshaft
        "P0010": e("Camshaft actuator circuit fault, bank 1", "The intake camshaft oil control solenoid circuit is out of range.", .moderate,
                   ["Failed oil control solenoid", "Dirty or degraded engine oil", "Open or shorted wiring"],
                   ["Rough idle", "Check engine light"],
                   ["Change oil and filter", "Test the solenoid with a multimeter", "Inspect the actuator harness"]),
        "P0011": e("Camshaft timing over-advanced, bank 1", "The ECU commanded a cam angle that the engine could not achieve — often called cam phaser rattle.", .high,
                   ["Sludge blocking the phaser oil passages", "Stuck oil control valve", "Stretched timing chain"],
                   ["Rattle on cold start", "Rough idle", "Loss of power"],
                   ["Verify oil change history and condition", "Test/replace the oil control valve", "Inspect the timing chain and phaser"]),
        "P0014": e("Camshaft timing over-advanced, bank 1 exhaust", "Exhaust camshaft timing is outside the commanded range.", .high,
                   ["Faulty exhaust cam phaser", "Low oil pressure", "Wiring fault to the actuator"]),
        "P0016": e("Crankshaft / camshaft position correlation, bank 1", "The relationship between the crank and cam sensors is wrong — a mechanical timing problem, not a sensor fault.", .critical,
                   ["Stretched or jumped timing chain/belt", "Failed timing chain tensioner", "Worn phaser or keyway"],
                   ["Hard starting", "Rough running", "Multiple misfire codes"],
                   ["Do not drive — risk of valve damage", "Verify timing marks against factory specs", "Replace the timing chain/belt and tensioner as a set"]),
        "P0017": e("Crankshaft / camshaft correlation, bank 1 sensor B", "Mechanical timing relationship is incorrect on the exhaust camshaft.", .critical,
                   ["Jumped timing chain", "Faulty cam phaser", "Wrong oil viscosity"],
                   ["Hard start", "Misfire", "Reduced power"],
                   ["Stop driving until verified", "Check timing alignment", "Inspect the exhaust cam phaser"]),

        // MARK: Oxygen sensors
        "P0030": e("O₂ heater control circuit, bank 1 sensor 1", "The heater circuit for the upstream oxygen sensor is not drawing the expected current.", .moderate,
                   ["Failed O₂ sensor heater", "Blown heater fuse", "Corroded connector"]),
        "P0031": e("O₂ heater circuit low, bank 1 sensor 1", "Heater circuit resistance is too low — usually the sensor element.", .moderate,
                   ["Shorted O₂ sensor heater", "Pinched harness shorting to ground"]),
        "P0032": e("O₂ heater circuit high, bank 1 sensor 1", "Heater circuit is open or drawing too little current.", .moderate,
                   ["Open heater element", "Open wiring", "Bad ground"]),
        "P0036": e("O₂ heater control circuit, bank 1 sensor 2", "Downstream oxygen sensor heater circuit fault.", .low,
                   ["Failed downstream O₂ sensor", "Fuse or wiring fault"]),
        "P0051": e("O₂ heater circuit, bank 2 sensor 1", "Upstream oxygen sensor heater circuit fault on bank 2.", .moderate,
                   ["Failed O₂ sensor", "Harness damage"]),

        // MARK: MAF / MAP / IAT / ECT / TPS
        "P0101": e("Mass air flow circuit range/performance", "The MAF sensor signal does not match what the ECU expects for the operating conditions.", .moderate,
                   ["Contaminated MAF sensor element", "Intake leak after the MAF", "K&N-style oiled air filter over-oiling"],
                   ["Rough idle", "Poor fuel economy", "Hesitation"],
                   ["Clean the MAF with dedicated spray", "Smoke test the intake", "Compare MAF g/s against expected at idle"]),
        "P0102": e("Mass air flow circuit low input", "Measured airflow is lower than physically plausible.", .moderate,
                   ["Failed MAF sensor", "Large intake leak", "Clogged air filter"]),
        "P0103": e("Mass air flow circuit high input", "Measured airflow is higher than physically plausible.", .moderate,
                   ["MAF sensor failure", "Wiring short"]),
        "P0106": e("Manifold absolute pressure circuit range/performance", "MAP sensor reading does not track expected manifold pressure.", .moderate,
                   ["Failed MAP sensor", "Vacuum leak", "Clogged sensor port"]),
        "P0107": e("MAP circuit low input", "Manifold pressure signal is below normal range.", .moderate,
                   ["Failed MAP sensor", "Open signal wire", "Intake leak"]),
        "P0108": e("MAP circuit high input", "Manifold pressure signal is above normal range.", .moderate,
                   ["Sensor failure", "Overboost", "Wiring short to voltage"]),
        "P0113": e("Intake air temperature circuit high input", "IAT sensor reports an unrealistically cold intake charge — usually an open circuit.", .low,
                   ["Failed IAT sensor", "Open wiring", "Disconnected sensor"],
                   ["Hard cold start", "Poor fuel economy"],
                   ["Inspect the IAT sensor connector", "Measure sensor resistance cold vs. warm"]),
        "P0117": e("Engine coolant temperature circuit low input", "Coolant temperature signal is unrealistically high.", .high,
                   ["Failed ECT sensor", "Low coolant level", "Overheating engine"],
                   ["Temperature gauge spike", "Fan running constantly", "Overheat warning"],
                   ["Stop and check coolant level when safe", "Verify actual temperature with an IR thermometer", "Test the ECT sensor"]),
        "P0118": e("Engine coolant temperature circuit high input", "Coolant temperature signal is unrealistically cold — usually an open circuit.", .moderate,
                   ["Failed ECT sensor", "Open wiring", "Trapped air in the cooling system"]),
        "P0120": e("Throttle position sensor circuit fault", "The ECU cannot trust the throttle position signal.", .high,
                   ["Worn throttle position sensor", "Carbon buildup in the throttle body", "Wiring fault"],
                   ["Reduced power / limp mode", "Erratic idle"],
                   ["Clean the throttle body", "Check signal voltage with a scan tool", "Perform a throttle relearn"]),
        "P0125": e("Insufficient coolant temperature for closed loop", "The engine never reached the temperature needed for fuel control — a stuck-open thermostat is the usual cause.", .low,
                   ["Stuck-open thermostat", "Failed ECT sensor", "Low coolant"],
                   ["Long warm-up times", "Poor fuel economy"],
                   ["Replace the thermostat", "Verify the ECT reading warms up normally"]),
        "P0128": e("Coolant thermostat below regulating temperature", "The engine warms up too slowly — thermostat is stuck open.", .low,
                   ["Stuck-open thermostat", "Failed ECT sensor", "Air pocket in cooling system"],
                   ["Weak heater", "Fuel economy drop", "No heat at idle"],
                   ["Replace the thermostat and gasket", "Bleed the cooling system"]),

        // MARK: Fuel trims
        "P0130": e("O₂ sensor circuit, bank 1 sensor 1", "Upstream oxygen sensor signal is out of range.", .moderate,
                   ["Failed O₂ sensor", "Vacuum leak", "Exhaust leak before the sensor"]),
        "P0131": e("O₂ sensor circuit low voltage, bank 1 sensor 1", "Upstream sensor is stuck lean.", .moderate,
                   ["Lean condition (vacuum leak, low fuel pressure)", "Failed O₂ sensor", "Exhaust leak"]),
        "P0133": e("O₂ sensor slow response, bank 1 sensor 1", "Upstream oxygen sensor is responding too slowly for closed-loop control.", .moderate,
                   ["Aged O₂ sensor", "Exhaust leak", "Contamination from coolant or oil burning"],
                   ["Poor fuel economy", "Failed emissions test"],
                   ["Replace the upstream O₂ sensor", "Check for exhaust leaks"]),
        "P0134": e("O₂ sensor circuit no activity, bank 1 sensor 1", "Upstream sensor signal is not changing at all.", .moderate,
                   ["Dead O₂ sensor", "Open heater or signal circuit", "Sensor unplugged"]),
        "P0135": e("O₂ heater circuit, bank 1 sensor 1", "Upstream oxygen sensor heater has failed.", .low,
                   ["Failed O₂ sensor heater", "Blown fuse", "Wiring fault"],
                   ["Check engine light after cold start"]),
        "P0137": e("O₂ sensor circuit low voltage, bank 1 sensor 2", "Downstream oxygen sensor is stuck lean.", .moderate,
                   ["Failed downstream O₂ sensor", "Exhaust leak", "Converter efficiency issue"]),
        "P0138": e("O₂ sensor circuit high voltage, bank 1 sensor 2", "Downstream oxygen sensor is stuck rich.", .moderate,
                   ["Failed O₂ sensor", "Rich running condition", "Short to voltage"]),
        "P0141": e("O₂ heater circuit, bank 1 sensor 2", "Downstream oxygen sensor heater fault.", .low,
                   ["Failed O₂ sensor heater", "Fuse or wiring"]),
        "P0151": e("O₂ sensor circuit low voltage, bank 2 sensor 1", "Bank 2 upstream sensor stuck lean.", .moderate,
                   ["Lean condition on bank 2", "Failed O₂ sensor", "Exhaust leak"]),
        "P0153": e("O₂ sensor slow response, bank 2 sensor 1", "Bank 2 upstream sensor responds too slowly.", .moderate,
                   ["Aged O₂ sensor", "Contamination", "Exhaust leak"]),
        "P0171": e("System too lean, bank 1", "The ECU added maximum fuel and still could not reach the target air/fuel ratio. A vacuum leak is the most common cause.", .moderate,
                   ["Vacuum or intake leak", "Dirty MAF sensor", "Weak fuel pump or clogged filter", "Leaking intake manifold gasket"],
                   ["Rough idle", "Hesitation", "Lean misfire"],
                   ["Smoke test the intake for leaks", "Clean the MAF sensor", "Check fuel pressure under load"]),
        "P0172": e("System too rich, bank 1", "Fuel delivery is higher than the ECU commands.", .moderate,
                   ["Leaking injector", "High fuel pressure", "Failed MAF sensor", "Stuck-open purge valve"],
                   ["Black smoke", "Fuel smell", "Fouled plugs"],
                   ["Check fuel pressure and fuel trims", "Test for leaking injectors", "Verify purge valve operation"]),
        "P0174": e("System too lean, bank 2", "Bank 2 is running lean — often a shared intake leak if bank 1 is also affected.", .moderate,
                   ["Intake gasket leak", "Vacuum leak", "MAF under-reporting"]),
        "P0175": e("System too rich, bank 2", "Bank 2 fuel delivery is excessive.", .moderate,
                   ["Leaking injector", "High fuel pressure", "MAF sensor fault"]),

        // MARK: Injectors
        "P0200": e("Injector circuit fault", "One or more fuel injector circuits is not operating correctly.", .high,
                   ["Failed injector", "Open or shorted harness", "ECM driver failure"],
                   ["Misfire", "Rough running", "Fuel smell"],
                   ["Measure injector resistance", "Check for injector pulse with a noid light", "Inspect harness"]),
        "P0201": e("Injector circuit fault, cylinder 1", "Cylinder 1 injector circuit is out of range.", .high,
                   ["Failed injector", "Wiring fault"]),
        "P0217": e("Engine over-temperature condition", "The engine exceeded its safe operating temperature.", .critical,
                   ["Low coolant", "Failed thermostat", "Failed water pump", "Cooling fan failure"],
                   ["Overheat warning", "Steam from the engine bay", "Power loss"],
                   ["Stop driving immediately", "Let the engine cool before opening the cooling system", "Pressure-test the cooling system"]),
        "P0230": e("Fuel pump primary circuit fault", "The fuel pump relay or driver circuit is not operating correctly.", .high,
                   ["Failed fuel pump relay", "Open wiring to the pump", "Failed fuel pump"],
                   ["No start", "Crank with no start", "Stalling"],
                   ["Check the fuel pump fuse and relay", "Verify pump prime at key-on", "Measure voltage at the pump connector"]),
        "P0234": e("Turbo overboost condition", "Boost exceeded the safe limit.", .high,
                   ["Stuck wastegate", "Faulty boost control solenoid", "Tuned ECU raising limits"],
                   ["Limp mode", "Loss of power"],
                   ["Inspect wastegate actuator operation", "Test the boost control solenoid"]),
        "P0299": e("Turbo underboost", "Boost pressure is lower than commanded.", .moderate,
                   ["Boost leak", "Failed turbo", "Stuck wastegate", "Clogged intercooler"],
                   ["Power loss", "Whistle or hiss"],
                   ["Pressure-test the charge piping", "Check wastegate movement", "Inspect the intercooler for leaks"]),

        // MARK: Misfires
        "P0300": e("Random / multiple cylinder misfire", "Misfires detected across more than one cylinder — the engine can damage the catalytic converter if driven hard.", .critical,
                   ["Worn spark plugs or coils", "Vacuum leak", "Low fuel pressure", "Mechanical engine fault"],
                   ["Shaking at idle", "Blinking check engine light", "Power loss"],
                   ["Replace plugs and inspect coils", "Check fuel trims and fuel pressure", "Do a compression/leak-down test if ignition checks out"]),
        "P0301": e("Cylinder 1 misfire", "Repeated misfires in cylinder 1.", .high,
                   ["Spark plug, coil, or injector", "Valve or compression issue", "Vacuum leak near cylinder 1"],
                   ["Rough idle", "Shudder under load", "Check-engine light"],
                   ["Swap the coil to another cylinder and watch the code move", "Replace plugs", "Compression test if unresolved"]),
        "P0302": e("Cylinder 2 misfire", "Repeated misfires in cylinder 2.", .high,
                   ["Ignition component", "Injector fault", "Mechanical issue"]),
        "P0303": e("Cylinder 3 misfire", "Repeated misfires in cylinder 3.", .high,
                   ["Ignition component", "Injector fault", "Mechanical issue"]),
        "P0304": e("Cylinder 4 misfire", "Repeated misfires in cylinder 4.", .high,
                   ["Ignition component", "Injector fault", "Mechanical issue"]),
        "P0305": e("Cylinder 5 misfire", "Repeated misfires in cylinder 5.", .high,
                   ["Ignition component", "Injector fault", "Mechanical issue"]),
        "P0306": e("Cylinder 6 misfire", "Repeated misfires in cylinder 6.", .high,
                   ["Ignition component", "Injector fault", "Mechanical issue"]),
        "P0307": e("Cylinder 7 misfire", "Repeated misfires in cylinder 7.", .high,
                   ["Ignition component", "Injector fault", "Mechanical issue"]),
        "P0308": e("Cylinder 8 misfire", "Repeated misfires in cylinder 8.", .high,
                   ["Ignition component", "Injector fault", "Mechanical issue"]),
        "P0316": e("Misfire detected at start-up", "Misfires occur in the first 1000 revolutions after start.", .high,
                   ["Coolant or oil leaking into a cylinder", "Weak ignition at cold start", "Low fuel pressure"]),
        "P0325": e("Knock sensor circuit fault, bank 1", "The knock sensor signal is missing or out of range.", .moderate,
                   ["Failed knock sensor", "Wiring fault", "Loose sensor"]),
        "P0335": e("Crankshaft position sensor circuit fault", "The ECU has lost the crankshaft signal — the engine may stall or not start.", .critical,
                   ["Failed crank sensor", "Damaged reluctor wheel", "Wiring/connector fault"],
                   ["Crank but no start", "Stalling", "Tachometer drop to zero"],
                   ["Check for a crank signal while cranking", "Inspect the sensor and reluctor", "Verify wiring continuity"]),
        "P0340": e("Camshaft position sensor circuit fault, bank 1", "The ECU cannot read the intake camshaft position.", .high,
                   ["Failed cam sensor", "Wiring fault", "Timing chain stretch"]),
        "P0345": e("Camshaft position sensor circuit fault, bank 2", "Bank 2 camshaft position signal is missing.", .high,
                   ["Failed cam sensor", "Wiring", "Mechanical timing"]),
        "P0351": e("Ignition coil A primary/secondary circuit", "The ECU cannot drive ignition coil A.", .high,
                   ["Failed coil", "Wiring fault", "ECM driver issue"],
                   ["Cylinder misfire", "No start"]),
        "P0352": e("Ignition coil B primary/secondary circuit", "Ignition coil B circuit fault.", .high,
                   ["Failed coil", "Wiring fault"]),

        // MARK: Emissions
        "P0401": e("EGR flow insufficient", "Commanded EGR flow is not being detected.", .moderate,
                   ["Clogged EGR passages", "Failed EGR valve", "Faulty DPFE sensor"],
                   ["Pinging under load", "Failed emissions test", "Surging"],
                   ["Remove and clean the EGR valve and ports", "Test the DPFE/EGR sensor", "Verify vacuum supply"]),
        "P0403": e("EGR control circuit fault", "The EGR valve control circuit is not operating correctly.", .moderate,
                   ["Failed EGR solenoid", "Wiring fault"]),
        "P0411": e("Secondary air injection incorrect flow", "Air injection system is not delivering the expected flow.", .moderate,
                   ["Failed air pump", "Leaking check valve", "Clogged passages"]),
        "P0420": e("Catalyst efficiency below threshold, bank 1", "The downstream O₂ sensor follows the upstream one too closely, meaning the converter is not storing oxygen as it should.", .moderate,
                   ["Worn-out catalytic converter", "Faulty downstream O₂ sensor", "Exhaust leak before the converter", "Engine misfire or rich running damaging the cat"],
                   ["Check engine light", "Failed emissions test"],
                   ["Fix any misfire or fuel-trim faults first", "Verify the downstream O₂ sensor is healthy", "Replace the converter only after diagnosing the root cause"]),
        "P0430": e("Catalyst efficiency below threshold, bank 2", "Bank 2 converter is below efficiency threshold.", .moderate,
                   ["Worn catalytic converter", "O₂ sensor fault", "Exhaust leak"]),
        "P0440": e("Evaporative emission system fault", "The EVAP system failed its self-test.", .low,
                   ["Loose or faulty gas cap", "Leaking EVAP hose", "Faulty purge or vent valve"],
                   ["Fuel smell", "Check engine light"],
                   ["Tighten or replace the gas cap, then clear the code", "Inspect EVAP hoses", "Run a smoke test if it returns"]),
        "P0442": e("Evaporative emission system small leak", "A small leak was detected in the EVAP system.", .low,
                   ["Gas cap seal", "Small hose crack", "Vent valve seep"]),
        "P0443": e("EVAP purge control valve circuit", "Purge solenoid circuit fault.", .low,
                   ["Failed purge valve", "Wiring fault"]),
        "P0455": e("Evaporative emission system large leak", "A large leak — often simply a loose fuel cap — was detected.", .low,
                   ["Loose or missing gas cap", "Disconnected EVAP hose", "Failed purge/vent valve"],
                   ["Fuel odor", "Check engine light"],
                   ["Check the gas cap first", "Inspect EVAP hoses at the tank and engine bay", "Smoke test the system"]),
        "P0456": e("Evaporative emission system very small leak", "A very small EVAP leak was detected.", .low,
                   ["Gas cap O-ring", "Small hose seep", "Vent valve"]),
        "P0457": e("EVAP system leak detected (fuel cap loose/off)", "The system detected the fuel cap is not sealing.", .low,
                   ["Fuel cap loose or damaged"],
                   ["Check engine light"],
                   ["Reseat or replace the fuel cap", "Clear the code and re-check after two drive cycles"]),

        // MARK: Speed, idle, electrical
        "P0500": e("Vehicle speed sensor fault", "The ECU is not receiving a valid vehicle speed signal.", .moderate,
                   ["Failed VSS", "Wiring fault", "ABS module issue feeding the signal"],
                   ["Speedometer inoperative", "Erratic shifting", "ABS light"],
                   ["Check the speed signal from the ABS module", "Inspect the VSS and wiring", "Verify tire size calibration"]),
        "P0505": e("Idle control system fault", "The engine cannot maintain target idle speed.", .moderate,
                   ["Carbon in the throttle body", "Failed idle air control valve", "Vacuum leak"],
                   ["Hunting idle", "Stalling at stops"],
                   ["Clean the throttle body and IAC passages", "Check for vacuum leaks", "Perform an idle relearn"]),
        "P0506": e("Idle speed lower than expected", "Idle RPM is below the target range.", .moderate,
                   ["Carbon buildup", "IAC valve fault", "Vacuum leak"]),
        "P0507": e("Idle speed higher than expected", "Idle RPM is above the target range.", .moderate,
                   ["Vacuum leak", "Throttle body calibration", "IAC valve"]),
        "P0521": e("Engine oil pressure sensor range/performance", "Oil pressure signal is inconsistent with engine operation.", .high,
                   ["Failed oil pressure sensor", "Low oil level", "Worn oil pump or bearings"],
                   ["Oil pressure warning", "Ticking lifters"],
                   ["Verify oil level and pressure with a mechanical gauge", "Replace the sensor only if pressure is confirmed good"]),
        "P0562": e("System voltage low", "Charging system voltage is below the normal range while running.", .moderate,
                   ["Failing alternator", "Loose or corroded battery terminals", "Worn serpentine belt"],
                   ["Dim lights", "Slow cranking", "Multiple unrelated codes"],
                   ["Test the battery and charging system under load", "Clean and tighten terminals", "Inspect the alternator belt and ground straps"]),
        "P0563": e("System voltage high", "Charging voltage is above the safe range.", .moderate,
                   ["Failed voltage regulator/alternator", "Wiring fault"],
                   ["Bulb failures", "Overcharged battery smell"]),
        "P0571": e("Brake switch circuit fault", "The ECU cannot confirm brake pedal position — cruise control may be disabled.", .moderate,
                   ["Failed brake light switch", "Misadjusted switch", "Wiring fault"],
                   ["Cruise control inoperative", "Brake lights stuck on or off"],
                   ["Test the brake switch operation", "Adjust or replace the switch"]),

        // MARK: Modules & transmission
        "P0601": e("Internal control module memory checksum error", "The ECU's internal memory failed a self-check.", .high,
                   ["Failed ECU", "Voltage spike", "Water intrusion"]),
        "P0606": e("PCM processor fault", "The powertrain control module reported an internal processor fault.", .high,
                   ["Failing PCM", "Power/ground issue", "Low voltage event"]),
        "P0620": e("Generator control circuit fault", "The PCM cannot control charging as expected.", .high,
                   ["Failed alternator", "Wiring fault", "PCM driver"]),
        "P0700": e("Transmission control system fault", "The transmission control module is reporting a fault — this is an informational code pointing to the TCM.", .high,
                   ["See the TCM-specific codes", "Low fluid", "Solenoid fault"],
                   ["Automatic transmission stored a code"],
                   ["Scan the transmission module for the real code", "Check fluid level and condition"]),
        "P0705": e("Transmission range sensor circuit fault", "Gear selector position cannot be determined reliably.", .high,
                   ["Failed range sensor", "Wiring fault", "Shifter linkage misalignment"],
                   ["Wrong gear display", "No start in some positions"]),
        "P0715": e("Input/turbine speed sensor circuit fault", "The transmission cannot read input shaft speed.", .high,
                   ["Failed speed sensor", "Wiring fault", "Internal transmission issue"],
                   ["Harsh or erratic shifts", "Limp mode"]),
        "P0730": e("Incorrect gear ratio", "Measured input/output speed ratio does not match the commanded gear — slipping or solenoid fault.", .high,
                   ["Low transmission fluid", "Worn clutches", "Failed shift solenoid", "Valve body issue"],
                   ["Slipping", "Flare between shifts", "Limp mode"],
                   ["Check fluid level and condition", "Scan the TCM for companion codes", "Avoid towing until repaired"]),
        "P0740": e("Torque converter clutch circuit fault", "The TCC solenoid circuit is not operating correctly.", .high,
                   ["Failed TCC solenoid", "Wiring fault", "Valve body issue"]),
        "P0741": e("Torque converter clutch stuck off", "The TCC is not engaging when commanded — fuel economy and heat suffer.", .high,
                   ["Worn converter clutch", "Solenoid fault", "Valve body wear"]),
        "P0750": e("Shift solenoid A fault", "Shift solenoid A circuit fault.", .high,
                   ["Failed solenoid", "Wiring fault", "Valve body contamination"]),
        "P0755": e("Shift solenoid B fault", "Shift solenoid B circuit fault.", .high,
                   ["Failed solenoid", "Wiring fault"]),
        "P0780": e("Shift error detected", "The transmission could not complete a commanded shift.", .high,
                   ["Solenoid or valve body fault", "Low fluid", "Internal wear"]),

        // MARK: Network & body
        "U0100": e("Lost communication with ECM/PCM", "Other modules cannot see the engine control module on the network.", .critical,
                   ["ECM power or ground fault", "CAN bus wiring fault", "Failed ECM"],
                   ["No start", "Multiple dash warnings", "Several modules offline"],
                   ["Check ECM fuses and grounds", "Inspect CAN bus resistance (≈60Ω across the bus)", "Look for water intrusion in connectors"]),
        "U0101": e("Lost communication with TCM", "The transmission control module dropped off the network.", .high,
                   ["TCM power/ground", "CAN wiring", "Failed TCM"]),
        "U0121": e("Lost communication with ABS module", "The ABS module is not responding on the network.", .high,
                   ["ABS module power/ground fault", "CAN wiring", "Failed ABS module"],
                   ["ABS and traction lights", "Speedometer may be inoperative"]),
        "U0140": e("Lost communication with body control module", "The BCM stopped responding on the network.", .high,
                   ["BCM power/ground", "CAN wiring", "Failed BCM"]),
        "U0155": e("Lost communication with instrument cluster", "The cluster dropped off the network.", .moderate,
                   ["Cluster power/ground", "CAN wiring", "Failed cluster"]),
        "C0035": e("Left front wheel speed sensor circuit", "The ABS module cannot read the left-front wheel speed.", .moderate,
                   ["Failed wheel speed sensor", "Damaged tone ring", "Wiring fault"],
                   ["ABS light", "Traction control disabled"],
                   ["Inspect the sensor and tone ring for debris/damage", "Check harness routing near the strut", "Compare all four wheel speeds live"]),
        "B0001": e("Driver frontal stage 1 deploy control", "Airbag circuit fault — airbags may not deploy as designed.", .critical,
                   ["Clock spring fault", "Seat wiring connector", "Airbag module fault"],
                   ["Airbag warning light"],
                   ["Have the SRS system diagnosed before driving", "Check under-seat connectors", "Do not probe airbag circuits with a standard meter"]),
        "B0083": e("Passenger seat weight sensor fault", "Occupant classification system fault — the passenger airbag may be suppressed.", .high,
                   ["Failed OCS sensor", "Wiring under the seat", "Calibration lost"]),
        "P1000": e("OBD readiness test not complete", "The ECU has not finished its self-tests since the codes were cleared.", .info,
                   ["Codes recently cleared", "Battery disconnected"],
                   ["Not necessarily a fault"],
                   ["Complete a full drive cycle before an emissions test"]),
        "P1133": e("O₂ sensor insufficient switching, bank 1 sensor 1", "Manufacturer-specific oxygen sensor performance fault.", .moderate,
                   ["Aged O₂ sensor", "Exhaust leak", "Fuel trim issue"]),
        "P1345": e("Cam/crank correlation fault (manufacturer-specific)", "Timing relationship between camshaft and crankshaft is out of spec.", .critical,
                   ["Jumped timing chain", "Distributor/phaser misalignment", "Sensor fault"],
                   ["No start or rough run", "Misfire"],
                   ["Verify mechanical timing", "Do not continue driving until confirmed"]),
        "P1450": e("EVAP system unable to bleed vacuum", "Manufacturer-specific EVAP fault — commonly a stuck purge or vent valve.", .low,
                   ["Stuck EVAP valve", "Blocked hose", "Fuel tank pressure sensor"]),
        "P2101": e("Throttle actuator control range/performance", "The electronic throttle did not reach the commanded position.", .high,
                   ["Carbon buildup in throttle body", "Failed throttle actuator", "Wiring fault"],
                   ["Reduced power mode", "Erratic idle"],
                   ["Clean the throttle body", "Perform a throttle relearn", "Inspect the actuator harness"]),
        "P2135": e("Throttle position sensors disagree", "The two throttle position signals do not match.", .high,
                   ["Failed throttle body", "Wiring fault", "Connector corrosion"],
                   ["Limp mode", "Hesitation"],
                   ["Inspect throttle body connector", "Replace throttle body if signals are confirmed bad"]),
        "P2181": e("Cooling system performance", "The engine is not maintaining expected coolant temperature under load.", .moderate,
                   ["Stuck thermostat", "Air pocket", "Radiator restriction", "Fan fault"],
                   ["Overheating in traffic", "Temperature swings"],
                   ["Bleed the cooling system", "Test the thermostat and fans"]),
        "P2002": e("Diesel particulate filter efficiency below threshold", "DPF is not trapping soot as expected.", .moderate,
                   ["Cracked DPF", "Failed pressure sensor", "Excessive soot from rich running"]),
        "P2463": e("Diesel particulate filter soot accumulation", "The DPF is loaded with soot and needs regeneration.", .moderate,
                   ["Short trips preventing regeneration", "Failed EGR", "Faulty sensor"],
                   ["Reduced power", "Limp mode"],
                   ["Perform a forced regeneration with a capable scan tool", "Address the root cause of soot production"])
    ]
}
