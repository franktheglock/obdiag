import Foundation

/// Wire-format decoding for diagnostic trouble codes.
///
/// Kept free of UI and knowledge-base dependencies so it can be exercised by
/// `scripts/check-parsers.sh` without a simulator.
enum DTCCodec {

    /// Parses DTC payloads from mode 03 (stored), 07 (pending) or 0A (permanent).
    ///
    /// SAE J1979 puts the number of DTCs (NODI) in the first byte after the mode
    /// byte, so a single P0456 arrives as `43 01 04 56`. Reading that count as
    /// the first code shifts everything by one byte — P0456 (`04 56`) decodes as
    /// P0104 (`01 04`) — exactly the mismatch seen against other scan tools. The
    /// count is only trusted when the arithmetic fits, so ECUs that omit it
    /// still parse.
    ///
    /// SAE J2012 layout of each code: byte 1 = system (bits 7-6), second
    /// character (bits 5-4), third character (bits 3-0); byte 2 = fourth and
    /// fifth characters.
    static func codes(fromPayload bytes: [UInt8]) -> [String] {
        var codes: [String] = []
        var index = 0
        var limit = Int.max

        if let count = nodiCount(in: bytes) {
            index = 1
            limit = count
            if count == 0 { return [] }
        }

        while index + 1 < bytes.count, codes.count < limit {
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
            codes.append(String(format: "%@%X%X%02X", system, secondCharacter, thirdCharacter, second))
        }
        return codes
    }

    /// Number of DTCs reported after the mode byte, when the payload carries it.
    static func nodiCount(in bytes: [UInt8]) -> Int? {
        guard let first = bytes.first else { return nil }
        let count = Int(first)
        guard count <= 0x20 else { return nil }

        let dtcBytes = bytes.count - 1
        let needed = count * 2
        if dtcBytes == needed { return count }
        if dtcBytes > needed, bytes[(1 + needed)...].allSatisfy({ $0 == 0 }) { return count }
        return nil
    }

    /// Encodes codes back to a mode 03/07/0A payload, count byte included. Used
    /// by the demo simulator so it speaks the same protocol as a real ECU.
    static func encode(_ codes: [String]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(clamping: codes.count)]
        for code in codes {
            let upper = code.uppercased()
            guard upper.count == 5 else { continue }
            let systemBits: UInt8
            switch upper.first {
            case "P": systemBits = 0
            case "C": systemBits = 1
            case "B": systemBits = 2
            case "U": systemBits = 3
            default: continue
            }
            let chars = Array(upper)
            guard let secondCharacter = UInt8(String(chars[1]), radix: 16),
                  let thirdCharacter = UInt8(String(chars[2]), radix: 16),
                  let rest = UInt8(String(chars[3...4]), radix: 16) else { continue }
            bytes.append((systemBits << 6) | ((secondCharacter & 0x03) << 4) | (thirdCharacter & 0x0F))
            bytes.append(rest)
        }
        // Pad to a plausible frame length; the decoder ignores trailing zeros.
        while bytes.count < 7 { bytes.append(0) }
        return bytes
    }
}
