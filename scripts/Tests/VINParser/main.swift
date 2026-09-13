import Foundation

var failures = 0

func check(_ name: String, _ lines: [String], _ expected: String?) {
    let response = OBDResponse(command: "0902", lines: lines)
    let vin = VINParser.extract(from: response)
    let ok = vin == expected
    if !ok { failures += 1 }
    print("\(ok ? "✓" : "✗") \(name.padding(toLength: 46, withPad: " ", startingAt: 0)) \(vin ?? "nil")\(ok ? "" : "   expected \(expected ?? "nil")")")
}

let expected = "1HGCM82633A004352"

// 1. ELM327 with headers off, 49 02 header repeated on every frame (most common).
check("repeated header per frame", [
    "49 02 01 31 48 47 43 4D 38 32",
    "49 02 02 36 33 33 41 30 30 34",
    "49 02 03 33 35 32 00 00",
], expected)

// 2. ISO-TP with frame indices and a length token — the case that used to be
//    dropped entirely because of the "0:" prefix.
check("ISO-TP frame indices", [
    "014",
    "0: 49 02 01 31 48 47 43",
    "1: 4D 38 32 36 33 33 41",
    "2: 30 30 34 33 35 32 00",
], expected)

// 3. Raw CAN frames with headers + PCI bytes.
check("raw CAN frames with headers", [
    "7E8 10 14 49 02 01 31 48 47",
    "7E8 21 43 4D 38 32 36 33 33",
    "7E8 22 41 30 30 34 33 35 32",
], expected)

// 4. ELM327 assembling everything onto one line.
check("single assembled line", [
    "49 02 01 31 48 47 43 4D 38 32 36 33 33 41 30 30 34 33 35 32",
], expected)

// 5. Padding after a short final frame.
check("short final frame with padding", [
    "49 02 01 31 48 47 43 4D 38 32 36",
    "49 02 02 33 33 41 30 30 34 33 35",
    "49 02 03 32 00 00 00 00 00 00 00",
], expected)

// 6. Left-padded VIN is still found.
check("odd length token tolerated", [
    "014",
    "1: 49 02 01 31 48 47 43 4D 38 32 36 33 33 41 30 30 34 33 35 32",
], expected)

// 7. Non-responses must not produce a VIN.
check("no data", ["NO DATA"], nil)
check("negative response", ["7F 09 31"], nil)
check("searching banner", ["SEARCHING...", "UNABLE TO CONNECT"], nil)

// 8. A VIN containing I/O/Q must be rejected, not truncated into a false positive.
check("rejects invalid characters", [
    "49 02 01 31 48 47 43 4D 49 4F 51 30 30 34 33 35 32 41 41 41 41",
], nil)

// 9. Real response captured from a Ram 1500 (spaces off, frame indices glued).
check("compact frame-index form (real car)", [
    "014",
    "0:490201334336",
    "1:545235454A364A",
    "2:47313530313532",
], "3C6TR5EJ6JG150152")

print(failures == 0 ? "\nall VIN parser checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
