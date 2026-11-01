import Foundation
import NohogCore

/// `nohog bench`: writes the same node_modules-style folder twice, once normally and once excluded
/// the way nohog excludes folders, and measures what Spotlight spends on each.
func bench(files: Int, store: ExclusionStore) throws {
    let base = canonicalPath(Paths.home) + "/nohog-bench-\(UUID().uuidString.prefix(8))"
    let indexedDir = base + "/indexed/node_modules", excludedDir = base + "/excluded/node_modules"
    defer {
        try? store.setExcluded(excludedDir, false)
        try? FileManager.default.removeItem(atPath: base)
    }
    let shown = base.replacingOccurrences(of: canonicalPath(Paths.home), with: "~")
    print("nohog bench: \(files) node_modules-style files, written twice (in \(shown))")

    print("1/3 measuring Spotlight's background activity (20s)…")
    let background = measure(seconds: 20)
    let backgroundRate = background.cpu / background.seconds
    let quietCPU = max(backgroundRate * Double(quietWindow) * 1.5, 0.2)

    print("2/3 writing \(files) files into a normal folder, measuring until Spotlight is idle…")
    let indexed = try runCondition(dir: indexedDir, files: files, exclude: false, store: store, quietCPU: quietCPU)
    print("3/3 writing \(files) files into an excluded folder, measuring until Spotlight is idle…")
    let excluded = try runCondition(dir: excludedDir, files: files, exclude: true, store: store, quietCPU: quietCPU)

    let net = { (run: BenchRun) in max(0, run.cpu - backgroundRate * run.seconds) }
    let saved = net(indexed) > 0 ? 100 * (1 - net(excluded) / net(indexed)) : 0
    print("""

    Spotlight CPU (mds + mds_stores + mdworker), background activity subtracted:
      without exclusion: \(format(net(indexed))) s CPU over \(Int(indexed.seconds)) s, \(indexed.indexedFiles) of \(files) files indexed
      with exclusion:    \(format(net(excluded))) s CPU over \(Int(excluded.seconds)) s, \(excluded.indexedFiles) of \(files) files indexed
      → \(Int(saved.rounded()))% less Spotlight CPU for this folder
    (background: \(format(backgroundRate * 60)) s CPU per minute; macOS \(macOSVersion()), \(chipName()))
    """)
}

private struct BenchRun {
    var cpu: Double
    var seconds: Double
    var indexedFiles: Int
}

private let quietWindow = 8

private func runCondition(dir: String, files: Int, exclude: Bool, store: ExclusionStore, quietCPU: Double) throws -> BenchRun {
    let fm = FileManager.default
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    fm.createFile(atPath: (dir as NSString).deletingLastPathComponent + "/package.json", contents: Data("{}".utf8))
    if exclude {
        let after = try applyExclusions(add: [dir], remove: [], current: try store.list(), store: store)
        // throw, not fail(): exiting here would skip the cleanup in bench()
        guard after.contains(dir) else { throw NohogError.spotlightAPIUnavailable("the benchmark exclusion was not recorded") }
        Thread.sleep(forTimeInterval: 2)
    }
    let token = "nohogbench\(UInt32.random(in: 0...UInt32.max))"
    var meter = CPUMeter(start: spotlightSample())
    let started = Date()
    for index in 0..<files {
        let sub = dir + "/pkg-\(index / 100)"
        if index % 100 == 0 { try fm.createDirectory(atPath: sub, withIntermediateDirectories: true) }
        fm.createFile(atPath: sub + "/index-\(index).js", contents: Data(benchFileContents(index: index, token: token).utf8))
    }
    let (cpu, seconds) = measureUntilIdle(meter: &meter, started: started, quietCPU: quietCPU)
    let count = run("/usr/bin/mdfind", ["-onlyin", dir, "-count", token]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    return BenchRun(cpu: cpu, seconds: seconds, indexedFiles: Int(count) ?? 0)
}

private func spotlightSample() -> [Int32: Double] {
    spotlightCPU(fromPS: run("/bin/ps", ["-axo", "pid=,time=,comm="]).output)
}

/// Fixed-length measurement (for the background rate).
private func measure(seconds: Int) -> (cpu: Double, seconds: Double) {
    var meter = CPUMeter(start: spotlightSample())
    let started = Date()
    for _ in 0..<seconds {
        Thread.sleep(forTimeInterval: 1)
        meter.add(spotlightSample())
    }
    return (meter.total, Date().timeIntervalSince(started))
}

/// Samples every second until Spotlight is quiet: at least 15 s, then stop once `quietWindow`
/// seconds pass with less than `quietCPU` seconds of CPU; at most 5 minutes.
private func measureUntilIdle(meter: inout CPUMeter, started: Date, quietCPU: Double) -> (cpu: Double, seconds: Double) {
    var totals: [Double] = []
    while true {
        Thread.sleep(forTimeInterval: 1)
        meter.add(spotlightSample())
        totals.append(meter.total)
        let elapsed = Date().timeIntervalSince(started)
        let recent = totals.count > quietWindow ? totals[totals.count - 1] - totals[totals.count - 1 - quietWindow] : .infinity
        if (elapsed >= 15 && recent < quietCPU) || elapsed >= 300 {
            return (meter.total, elapsed)
        }
    }
}

private func format(_ seconds: Double) -> String { String(format: "%.1f", seconds) }
