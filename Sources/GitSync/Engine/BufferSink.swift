import Foundation

// Adapter: the SyncEngine's EngineSink that feeds the EventBuffer, which
// AppState drains at 10Hz into @Published state. This seam is what lets the
// engine reuse the buffer's two-lane bookkeeping / finalizeRun / coalescing.
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
