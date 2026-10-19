/// Finds the terminal's cursor-position report (ESC [ row ; col R) in bytes read from stdin, and returns it with
/// every other byte (keys the user typed meanwhile) so they can still be handled as input.
public func extractCursorReport(from bytes: [UInt8]) -> (row: Int, col: Int, rest: [UInt8])? {
    for start in bytes.indices where bytes[start] == 0x1B {
        var i = start + 1
        guard i < bytes.count, bytes[i] == UInt8(ascii: "[") else { continue }
        i += 1
        var numbers: [Int] = [], current = 0, hasDigit = false
        while i < bytes.count {
            let b = bytes[i]
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) {
                current = current * 10 + Int(b - UInt8(ascii: "0"))
                hasDigit = true
            } else if b == UInt8(ascii: ";"), hasDigit, numbers.isEmpty {
                numbers.append(current)
                (current, hasDigit) = (0, false)
            } else if b == UInt8(ascii: "R"), hasDigit, numbers.count == 1 {
                return (numbers[0], current, Array(bytes[..<start] + bytes[(i + 1)...]))
            } else {
                break
            }
            i += 1
        }
    }
    return nil
}
