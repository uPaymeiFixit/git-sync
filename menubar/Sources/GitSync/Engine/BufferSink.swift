import Foundation

// Adapter: lets the native SyncEngine feed the existing EventBuffer, which
// AppState already drains at 10Hz into @Published state. This is the seam
// that keeps every downstream invariant (two-lane bookkeeping, finalizeRun,
// coalescing) byte-for-byte unchanged — only the event PRODUCER changes from
// the Python+pipe to the in-process engine.
struct BufferSink: EngineSink {
    let buffer: EventBuffer

    func emit(_ event: SyncEvent) async {
        await buffer.push(event)
    }
    func logLine(_ line: String, platform: String) async {
        await buffer.pushLogLine(line, platform: platform)
    }
    func platformFinished(_ platform: String, exitCode: Int32) async {
        await buffer.pushPlatformFinish(platform, exitCode: exitCode)
    }
    func allFinished() async {
        await buffer.markAllFinished()
    }
    func individualFinished(_ id: RepoID, exitCode: Int32) async {
        await buffer.pushIndividualFinish(id, exitCode: exitCode)
    }
}
