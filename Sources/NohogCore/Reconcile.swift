import Foundation

public enum NohogError: Error, CustomStringConvertible {
    case spotlightAPIUnavailable(String)

    public var description: String {
        switch self {
        case .spotlightAPIUnavailable(let detail):
            return "Spotlight exclusion API unavailable (\(detail)). macOS may have changed it; run `nohog selftest`."
        }
    }
}

/// The Spotlight Privacy list.
public protocol ExclusionStore {
    func list() throws -> [String]
    func setExcluded(_ path: String, _ excluded: Bool) throws
}

/// The private Metadata.framework calls behind System Settings > Spotlight > Search Privacy.
/// Verified on macOS 27.2: works as a normal user, applies live, purges already-indexed content.
public final class SpotlightExclusionStore: ExclusionStore {
    private typealias CopyFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias SetFn = @convention(c) (CFString, UInt32) -> Unmanaged<CFTypeRef>?
    private static let frameworkPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Metadata"

    private let copyExclusionList: CopyFn
    private let setExclusion: SetFn

    public init() throws {
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            throw NohogError.spotlightAPIUnavailable("cannot load Metadata.framework")
        }
        guard let copy = dlsym(handle, "_MDCopyExclusionList"), let set = dlsym(handle, "_MDSetExclusion") else {
            throw NohogError.spotlightAPIUnavailable("symbols _MDCopyExclusionList/_MDSetExclusion missing")
        }
        copyExclusionList = unsafeBitCast(copy, to: CopyFn.self)
        setExclusion = unsafeBitCast(set, to: SetFn.self)
    }

    public func list() throws -> [String] {
        guard let array = copyExclusionList()?.takeRetainedValue() else { return [] }
        guard let paths = (array as NSArray) as? [String] else {
            throw NohogError.spotlightAPIUnavailable("exclusion list has an unexpected shape")
        }
        return paths
    }

    public func setExcluded(_ path: String, _ excluded: Bool) throws {
        // The return value is undocumented (nil in practice); callers verify by re-listing.
        _ = setExclusion(path as CFString, excluded ? 1 : 0)
    }
}

/// What nohog remembers between runs.
public struct State: Codable, Equatable, Sendable {
    /// Exclusions nohog added. Anything else in the Privacy list belongs to the user and is never touched.
    public var managed: [String] = []
    public var lastOSBuild: String?

    public init(managed: [String] = [], lastOSBuild: String? = nil) {
        self.managed = managed
        self.lastOSBuild = lastOSBuild
    }

    /// A missing file is an empty state. A corrupt file throws, so it is never silently overwritten.
    public static func load(from url: URL) throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct Plan: Equatable, Sendable {
    public var add: [String]
    public var remove: [String]
    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
}

public enum Planner {
    /// `/Volumes/<name>` for paths on another volume; nil for the boot volume (always mounted).
    public static func volumeRoot(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// - add: desired but not currently excluded (also re-adds anything a macOS update dropped).
    /// - remove: only nohog-managed entries that are no longer desired and lie in a part of the disk
    ///   the scan actually looked at. Unmounted drives, denied access and failed listings never prune.
    public static func plan(
        desired: [String],
        current: [String],
        managed: [String],
        scannedRoots: [String],
        unreadable: [String]
    ) -> Plan {
        let desiredSet = Set(desired), currentSet = Set(current)
        let add = desiredSet.subtracting(currentSet).sorted()
        let remove = Set(managed).filter { path in
            currentSet.contains(path)
                && !desiredSet.contains(path)
                && scannedRoots.contains { isWithin(path, $0) }
                && !unreadable.contains { isWithin(path, $0) }
        }.sorted()
        return Plan(add: add, remove: remove)
    }

    /// Managed set after applying a plan, derived from what Spotlight actually reports (`after`),
    /// not from what we asked for. Entries on unmounted volumes are kept (the list may omit them).
    public static func nextManaged(managed: [String], added: [String], after: [String], isMounted: (String) -> Bool) -> [String] {
        let afterSet = Set(after)
        return Set(managed + added).filter { path in
            afterSet.contains(path) || !(volumeRoot(of: path).map(isMounted) ?? true)
        }.sorted()
    }

    public static func isMounted(_ volumeRoot: String) -> Bool {
        isDirectory(volumeRoot)
    }
}

/// Desired exclusions for a config: scanned junk dirs plus existing extra paths.
public func desiredExclusions(config: Config) -> (desired: [String], scan: ScanResult) {
    let scan = JunkScanner(config: config).scan(roots: config.roots)
    let skip = config.skipPaths.map(canonicalPath)
    let extras = config.extraPaths.filter(isDirectory).map(canonicalPath).filter { path in
        !skip.contains { isWithin(path, $0) }
    }
    return (Array(Set(scan.found + extras)).sorted(), scan)
}

/// Applies changes and returns Spotlight's list afterwards.
/// mds drops requests while it is busy purging or re-indexing a large folder (observed: of a burst
/// of 8-10 changes on big folders, only the first ~3 landed). Setting is idempotent, so whatever is
/// still pending is re-issued, with backoff.
public func applyExclusions(
    add: [String],
    remove: [String],
    current: [String],
    store: ExclusionStore,
    wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
) throws -> [String] {
    var after = current
    for delay in [0, 1, 2, 4, 8] as [TimeInterval] {
        let present = Set(after)
        let pendingAdds = add.filter { !present.contains($0) }
        let pendingRemoves = remove.filter(present.contains)
        if pendingAdds.isEmpty && pendingRemoves.isEmpty { break }
        wait(delay)
        for path in pendingAdds { try store.setExcluded(path, true) }
        for path in pendingRemoves { try store.setExcluded(path, false) }
        after = try store.list()
    }
    return after
}

public struct ReconcileOutcome: Equatable, Sendable {
    public var plan: Plan
    /// Requested changes that Spotlight's list does not reflect afterwards.
    public var failedAdds: [String] = []
    public var failedRemoves: [String] = []
    /// The Privacy list after this run (before it, for a dry run).
    public var excluded: [String]
    public var desiredCount: Int
    public var scannedRoots: [String]

    public var succeeded: Bool { failedAdds.isEmpty && failedRemoves.isEmpty }
}

/// One reconcile pass: next state = f(config, previous state, Spotlight's list).
public func reconcile(
    config: Config,
    state: State,
    store: ExclusionStore,
    dryRun: Bool,
    isMounted: (String) -> Bool = Planner.isMounted,
    wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
) throws -> (outcome: ReconcileOutcome, state: State) {
    let (desired, scan) = desiredExclusions(config: config)
    let current = try store.list()
    let plan = Planner.plan(
        desired: desired, current: current, managed: state.managed,
        scannedRoots: scan.scannedRoots, unreadable: scan.unreadable)
    if dryRun || plan.isEmpty {
        return (ReconcileOutcome(plan: plan, excluded: current, desiredCount: desired.count, scannedRoots: scan.scannedRoots), state)
    }

    let after = try applyExclusions(add: plan.add, remove: plan.remove, current: current, store: store, wait: wait)
    let afterSet = Set(after)

    var next = state
    next.managed = Planner.nextManaged(managed: state.managed, added: plan.add, after: after, isMounted: isMounted)
    let outcome = ReconcileOutcome(
        plan: plan,
        failedAdds: plan.add.filter { !afterSet.contains($0) },
        failedRemoves: plan.remove.filter(afterSet.contains),
        excluded: after,
        desiredCount: desired.count,
        scannedRoots: scan.scannedRoots)
    return (outcome, next)
}
