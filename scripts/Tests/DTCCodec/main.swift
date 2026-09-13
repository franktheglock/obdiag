import Foundation

// Parser regression check — run with: scripts/check-parsers.sh
// The expectations come from real adapter logs and the SAE J1979 format.

var failures = 0

func check(_ name: String, _ payload: [UInt8], _ expected: [String]) {
    let got = DTCCodec.codes(fromPayload: payload)
    let ok = got == expected
    if !ok { failures += 1 }
    print("\(ok ? "✓" : "✗") \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(got)\(ok ? "" : "   expected \(expected)")")
}

// A real RAM 1500 reported 43 01 04 56 for modes 03, 07 and 0A: one DTC (NODI
// 01) whose bytes are 04 56 — P0456. Reading the count as the first code
// produced three bogus P0104 rows.
check("RAM mode 03 (real log)", [0x01, 0x04, 0x56], ["P0456"])
check("RAM mode 07 (real log)", [0x01, 0x04, 0x56], ["P0456"])
check("RAM mode 0A (real log)", [0x01, 0x04, 0x56], ["P0456"])
check("two codes plus padding", [0x02, 0x04, 0x20, 0x01, 0x71, 0x00, 0x00], ["P0420", "P0171"])
check("one code, zero padded", [0x01, 0x04, 0x20, 0x00, 0x00, 0x00, 0x00], ["P0420"])
check("no codes", [0x00, 0x00, 0x00, 0x00], [])
check("legacy payload without count", [0x01, 0x33, 0x01, 0x71, 0x00, 0x00], ["P0133", "P0171"])
check("network code", [0x01, 0xC1, 0x00], ["U0100"])
check("chassis code", [0x01, 0x40, 0x35], ["C0035"])   // C = system bits 01
check("empty payload", [], [])

// Round trip through the encoder used by the demo adapter.
let encoded = DTCCodec.encode(["P0420", "P0171"])
check("demo encoder round trip", encoded, ["P0420", "P0171"])

print(failures == 0 ? "\nall DTC codec checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
