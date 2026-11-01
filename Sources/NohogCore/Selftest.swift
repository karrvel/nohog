import Foundation

public enum SelftestResult: Equatable, Sendable {
    case pass
    case fail(String)
    case inconclusive(String)

    public var summary: String {
        switch self {
        case .pass: return "selftest passed: Spotlight honors nohog exclusions"
        case .fail(let why): return "selftest FAILED: \(why)"
        case .inconclusive(let why): return "selftest inconclusive: \(why)"
        }
    }
}

/// Spotlight query used by the selftest: indexed paths under `dir` whose content contains `token`.
public typealias SpotlightSearch = (_ token: String, _ dir: String) -> [String]

/// End-to-end check of the exclusion API on this macOS: inside a fresh folder under `parent`, an
/// excluded subfolder must stay out of the index while a control subfolder gets indexed.
/// Cleans up the folder and the exclusion whatever happens.
public func runSelftest(
    store: ExclusionStore,
    parent: String,
    search: SpotlightSearch,
    wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    attempts: Int = 30
) -> SelftestResult {
    let fm = FileManager.default
    let dir = parent + "/nohog-selftest-\(UUID().uuidString.prefix(8))"
    let control = dir + "/control", excluded = dir + "/excluded"
    let token = "nohogselftest\(UInt32.random(in: 0...UInt32.max))"
    do {
        try fm.createDirectory(atPath: control, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: excluded, withIntermediateDirectories: true)
        try store.setExcluded(excluded, true)
    } catch {
        try? fm.removeItem(atPath: dir)
        return .fail("setup: \(error)")
    }
    defer {
        try? store.setExcluded(excluded, false)
        try? fm.removeItem(atPath: dir)
    }
    guard (try? store.list())?.contains(excluded) == true else {
        return .fail("the exclusion was not recorded in Spotlight's list")
    }
    wait(2)
    fm.createFile(atPath: control + "/probe.txt", contents: Data(token.utf8))
    fm.createFile(atPath: excluded + "/probe.txt", contents: Data(token.utf8))

    var hits = search(token, dir)
    for _ in 0..<attempts where !hits.contains(where: { isWithin($0, control) }) {
        wait(1)
        hits = search(token, dir)
    }
    guard hits.contains(where: { isWithin($0, control) }) else {
        return .inconclusive("Spotlight did not index the control file within \(attempts)s (indexing off or busy)")
    }
    wait(3) // grace period: an ignored exclusion would show up by now
    return search(token, dir).contains { isWithin($0, excluded) } ? .fail("a file inside an excluded folder was indexed") : .pass
}

/// Runs `selftest` unless it already passed on this OS `build`; returns nil when skipped.
/// Only a pass is recorded, so a failure or an inconclusive run is checked again next time.
public func selftestIfNeeded(stateURL: URL, build: String, selftest: () -> SelftestResult) -> SelftestResult? {
    guard var state = try? State.load(from: stateURL), state.lastOSBuild != build else { return nil }
    let result = selftest()
    if result == .pass {
        state.lastOSBuild = build
        try? state.save(to: stateURL)
    }
    return result
}
