import Foundation

// Splits a stream of Data chunks into newline-terminated UTF-8 strings.
// Used by SyncRunner.attach to turn pipe reads into per-line events.
//
// Not thread-safe by itself: FileHandle.readabilityHandler fires
// serially per handle, so the caller's single producer is the contract.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    // Append a chunk, return any complete lines (without the trailing \n).
    // Lines are decoded as UTF-8 with lossy replacement for malformed
    // bytes — never throws.
    func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let nlIndex = buffer.firstIndex(of: 0x0A) {  // '\n'
            let lineData = buffer.subdata(in: buffer.startIndex..<nlIndex)
            buffer.removeSubrange(buffer.startIndex...nlIndex)
            // Strip an optional preceding \r for CRLF inputs.
            let trimmed: Data
            if lineData.last == 0x0D {
                trimmed = lineData.dropLast()
            } else {
                trimmed = lineData
            }
            lines.append(String(decoding: trimmed, as: UTF8.self))
        }
        return lines
    }

    // Returns any trailing partial line (no \n) after EOF, then resets.
    func flushRemainder() -> String? {
        guard !buffer.isEmpty else { return nil }
        let trimmed: Data
        if buffer.last == 0x0D {
            trimmed = buffer.dropLast()
        } else {
            trimmed = buffer
        }
        buffer.removeAll(keepingCapacity: false)
        return String(decoding: trimmed, as: UTF8.self)
    }
}
