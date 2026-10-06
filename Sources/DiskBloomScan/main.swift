import Darwin
import DiskBloomCore
import Dispatch
import Foundation

private struct CommandOptions {
    var path: String?
    var allLocal = false
    var repeatCount = 1
    var warmupCount = 0
    var workers = LocalStorageScanner.defaultMaximumWorkers
    var depth: Int?
    var json = false
    var compare = false
    var engine = Engine.native
    var help = false

    init(arguments: [String]) throws {
        var index = 0
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CommandError("Missing value for \(flag)") }
            return arguments[index]
        }
        func integer(for flag: String, range: ClosedRange<Int>) throws -> Int {
            let text = try value(for: flag)
            guard let number = Int(text), range.contains(number) else { throw CommandError("\(flag) must be between \(range.lowerBound) and \(range.upperBound)") }
            return number
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--all-local": allLocal = true
            case "--repeat": repeatCount = try integer(for: argument, range: 0...1_000)
            case "--warmup": warmupCount = try integer(for: argument, range: 0...20)
            case "--workers": workers = try integer(for: argument, range: 1...32)
            case "--depth": depth = try integer(for: argument, range: 0...64)
            case "--json": json = true
            case "--compare": compare = true
            case "--engine":
                let text = try value(for: argument)
                guard let selected = Engine(rawValue: text) else { throw CommandError("--engine must be native or foundation") }
                engine = selected
            case "--help", "-h": help = true
            case "--":
                index += 1
                guard index == arguments.count - 1, path == nil else { throw CommandError("Specify exactly one scan path after --") }
                path = arguments[index]
            default:
                guard !argument.hasPrefix("-"), path == nil else { throw CommandError("Unknown or duplicate argument: \(argument)") }
                path = argument
            }
            index += 1
        }
        guard !(allLocal && path != nil) else { throw CommandError("Use either --all-local or a folder path") }
    }

    var isBenchmark: Bool { json || compare || repeatCount != 1 || warmupCount > 0 }
}

private struct CommandError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum Engine: String, Codable, CaseIterable {
    case native, foundation
    var strategy: DiskScanner.MetadataStrategy { self == .native ? .automatic : .foundation }
}

private struct Measurement: Encodable {
    let type = "scan"
    let engine: Engine
    let iteration: Int
    let warmup: Bool
    let workerLimit: Int
    let fullDiskAccess: Bool
    let seconds: Double
    let wallSeconds: Double
    let cpuSeconds: Double
    let processPeakRSSBytes: Int64
    let files: Int
    let folders: Int
    let allocatedBytes: Int64
    let unreadable: Int
    let scannedAt: Date
}

private struct Summary: Encodable {
    let type = "summary"
    let engine: Engine
    let runs: Int
    let minimumSeconds: Double
    let medianSeconds: Double?
    let meanSeconds: Double
    let maximumSeconds: Double
}

private struct Statistics {
    var count = 0
    var total = 0.0
    var minimum = Double.infinity
    var maximum = 0.0
    var durations: [Double] = []

    mutating func record(_ seconds: Double, keepSamples: Bool) {
        count += 1
        total += seconds
        minimum = min(minimum, seconds)
        maximum = max(maximum, seconds)
        if keepSamples { durations.append(seconds) }
    }

    func summary(engine: Engine) -> Summary? {
        guard count > 0 else { return nil }
        let sorted = durations.sorted()
        let median: Double?
        if sorted.isEmpty { median = nil }
        else if sorted.count % 2 == 1 { median = sorted[sorted.count / 2] }
        else { median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 }
        return Summary(engine: engine, runs: count, minimumSeconds: minimum, medianSeconds: median, meanSeconds: total / Double(count), maximumSeconds: maximum)
    }
}

private func usage() -> (cpu: Double, peakRSS: Int64) {
    var value = rusage()
    getrusage(RUSAGE_SELF, &value)
    let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    return (cpu, Int64(value.ru_maxrss))
}

private func hasFullDiskAccess() -> Bool {
    let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    return probe.withUnsafeFileSystemRepresentation { path in
        guard let path else { return false }
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        Darwin.close(descriptor)
        return true
    }
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private let help = """
Usage: diskbloom-scan [folder] [options]
       diskbloom-scan --all-local --repeat 3 --json

  --all-local           Use the app's local volumes, exclusions and scan plan.
                        Requires Full Disk Access in the launching terminal.
  --repeat N            Repeat N times; 0 repeats until Ctrl-C (default: 1).
  --warmup N            Run N unmeasured warmups for each engine (default: 0).
  --workers N           Maximum parallel workers, 1...32 (default: available CPUs, capped at 8).
  --depth N             Retained tree depth; default: 4 for all-local, 8 for folders.
  --engine ENGINE       native (bulk metadata) or foundation (reference backend).
  --compare             Run both backends, alternating order each iteration.
  --json                JSON Lines measurements and summaries, without file paths.
  --help                Show this help.

Every run scans again. Benchmarks never read or write the app's snapshot cache.
Repeated runs naturally warm the filesystem cache. No cache flushing is performed.
The foundation backend uses the current tree-selection code; it is not the old app.
"""

private let token = ScanCancellationToken()
// Dispatch handles signals outside the POSIX signal handler, where taking a lock
// or using Foundation would be unsafe.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
private let signalSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
    source.setEventHandler { token.cancel() }
    source.resume()
    return source
}

private var statistics: [Engine: Statistics] = [:]
private var commandOptions: CommandOptions?

private func printSummaries(json: Bool) throws {
    for engine in Engine.allCases {
        guard let summary = statistics[engine]?.summary(engine: engine) else { continue }
        if json { try writeJSON(summary) }
        else {
            let median = summary.medianSeconds.map { String(format: "%.3fs", $0) } ?? "n/a"
            print(String(format: "%@: %d runs · min %.3fs · median %@ · mean %.3fs · max %.3fs", engine.rawValue, summary.runs, summary.minimumSeconds, median, summary.meanSeconds, summary.maximumSeconds))
        }
    }
}

do {
    let options = try CommandOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    commandOptions = options
    if options.help { print(help); exit(0) }
    let fullDiskAccess = hasFullDiskAccess()
    if options.allLocal && !fullDiskAccess {
        throw CommandError("Full Disk Access is not available. Run this benchmark from a terminal already granted Full Disk Access (for example Terminal or cmux). No scan was started.")
    }
    let path = options.path ?? FileManager.default.homeDirectoryForCurrentUser.path
    let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    let selectedEngines = options.compare ? Engine.allCases : [options.engine]
    let totalRounds = options.repeatCount == 0 ? nil : options.warmupCount + options.repeatCount
    var round = 0
    while totalRounds == nil || round < totalRounds! {
        if token.isCancelled { throw DiskScanError.cancelled }
        let warmup = round < options.warmupCount
        let iteration = warmup ? round + 1 : round - options.warmupCount + 1
        let ordered = round % 2 == 0 ? selectedEngines : Array(selectedEngines.reversed())
        for engine in ordered {
            if token.isCancelled { throw DiskScanError.cancelled }
            let scanOptions = DiskScanner.Options(
                maximumTreeDepth: options.depth ?? (options.allLocal ? 4 : 8),
                maximumChildrenPerFolder: options.allLocal ? 80 : 160,
                metadataStrategy: engine.strategy
            )
            let showProgress = !options.json
            fputs("\(engine.rawValue) · \(warmup ? "warmup" : "scan") \(iteration)\n", stderr)
            let progress: @Sendable (ScanProgress) -> Void = { update in
                guard showProgress else { return }
                fputs("\r\(DiskBloomFormat.count(update.items))개 · \(DiskBloomFormat.bytes(update.bytes))", stderr)
                fflush(stderr)
            }
            let started = ProcessInfo.processInfo.systemUptime
            let initialUsage = usage()
            let result: ScanResult
            if options.allLocal {
                result = try await LocalStorageScanner.scanAll(options: scanOptions, cancellationToken: token, maximumWorkers: options.workers, progress: progress)
            } else {
                let target = LocalScanTarget(id: root.path, name: root.lastPathComponent, url: root, isSystemVolume: root.path == "/")
                var folderOptions = scanOptions
                // A root-volume path gets the same cloud / APFS exclusions as --all-local.
                folderOptions.excludedPaths = LocalStorageScanner.excludedPaths(for: target)
                result = try await LocalStorageScanner.scan(target: target, options: folderOptions, cancellationToken: token, maximumWorkers: options.workers, progress: progress)
            }
            let wall = ProcessInfo.processInfo.systemUptime - started
            let finalUsage = usage()
            if showProgress { fputs("\n", stderr) }
            if !warmup { statistics[engine, default: Statistics()].record(result.elapsed, keepSamples: options.repeatCount != 0) }
            let measurement = Measurement(engine: engine, iteration: iteration, warmup: warmup, workerLimit: options.workers,
                                          fullDiskAccess: fullDiskAccess, seconds: result.elapsed, wallSeconds: wall,
                                          cpuSeconds: finalUsage.cpu - initialUsage.cpu, processPeakRSSBytes: finalUsage.peakRSS,
                                          files: result.root.fileCount, folders: result.root.folderCount, allocatedBytes: result.root.size,
                                          unreadable: result.unreadableCount, scannedAt: result.scannedAt)
            if options.json { try writeJSON(measurement) }
            else {
                print(String(format: "%@ · %.3fs · %@ · files %d · folders %d · unreadable %d", engine.rawValue, result.elapsed, DiskBloomFormat.bytes(result.root.size), result.root.fileCount, result.root.folderCount, result.unreadableCount))
                if !options.isBenchmark {
                    print("\n가장 큰 파일")
                    for file in result.largestFiles.prefix(20) { print("\(DiskBloomFormat.bytes(file.size))\t\(file.path)") }
                }
            }
        }
        round += 1
    }
    if options.isBenchmark { try printSummaries(json: options.json) }
} catch DiskScanError.cancelled {
    try? printSummaries(json: commandOptions?.json == true)
    fputs("\n스캔을 중단했습니다.\n", stderr)
    exit(130)
} catch {
    fputs("오류: \(error.localizedDescription)\n", stderr)
    exit(1)
}
withExtendedLifetime(signalSources) {}
