import CoreServices
import Foundation
import NohogCore

/// The background agent (`nohog watch`, started by launchd). Reconciles at start, when a junk
/// folder appears under a root, when a drive mounts, and hourly (catches resets by macOS).
/// All state is confined to `queue`: FSEvents, the timer and the debounce all deliver there,
/// so there is no locking. (Not MainActor: `dispatchMain()` exits the main thread, and the main
/// queue is then drained by worker threads, which fails MainActor's main-thread check.)
final class Agent: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.nohog.agent")
    private let store: ExclusionStore
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var timer: DispatchSourceTimer?
    private var pending = false
    // Filter inputs for events, refreshed by every reconcile.
    private var ruleNames: Set<String> = []
    private var roots: [String] = []
    private var excluded: [String] = []

    private static let debounce: TimeInterval = 2
    private static let hourly: TimeInterval = 3600
    private static let triggerFlags = UInt32(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagMustScanSubDirs)

    init(store: ExclusionStore) {
        self.store = store
    }

    func start() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0) // launchd sends stdout to the log file
        log("started on macOS \(osBuild())")
        queue.async { [self] in
            selftestAfterOSUpdate()
            reconcileNow(reason: "start")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.hourly, repeating: Self.hourly)
            timer.setEventHandler { [unowned self] in reconcileNow(reason: "hourly") }
            timer.resume()
            self.timer = timer
        }
        dispatchMain()
    }

    /// After an OS update (or on first start), prove the private API still works. If it does not,
    /// tell the user and stop cleanly: launchd does not restart a successful exit, and the check
    /// runs again at the next login.
    private func selftestAfterOSUpdate() {
        guard let result = selftestIfNeeded(store: store) else { return }
        log(result.summary)
        guard case .fail = result else { return }
        notify("Spotlight exclusions stopped working on this macOS, so nohog paused. See \(Paths.log)")
        exit(0)
    }

    private func reconcileNow(reason: String) {
        do {
            let config = try Config.load(from: Paths.config, home: Paths.home)
            let state = try State.load(from: Paths.state)
            let (outcome, next) = try reconcile(config: config, state: state, store: store, dryRun: false)
            if next != state { try next.save(to: Paths.state) }
            ruleNames = Set(config.rules.map(\.name))
            roots = outcome.scannedRoots
            excluded = outcome.excluded
            watch(watchRoots(for: config.roots))
            report(outcome, reason: reason)
        } catch {
            log("reconcile (\(reason)) failed: \(error)")
        }
    }

    private func report(_ outcome: ReconcileOutcome, reason: String) {
        if outcome.plan.isEmpty && reason != "start" { return } // quiet when nothing happens
        let summary = "reconcile (\(reason)): +\(outcome.plan.add.count) -\(outcome.plan.remove.count), \(outcome.desiredCount) folders desired"
        log(summary)
        for path in outcome.plan.add { log("  + \(path)") }
        for path in outcome.plan.remove { log("  - \(path)") }
        for path in outcome.failedAdds + outcome.failedRemoves { log("  ! Spotlight did not apply: \(path)") }
    }

    fileprivate func handle(paths: [String], flags: [UInt32]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let relevant = flags.contains { $0 & Self.triggerFlags != 0 }
            || paths.contains { isJunkEvent($0, ruleNames: ruleNames, roots: roots, excluded: excluded) }
        guard relevant, !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + Self.debounce) { [unowned self] in
            pending = false
            reconcileNow(reason: "change")
        }
    }

    /// (Re)creates the FSEvents stream when the set of watched directories changes.
    private func watch(_ directories: [String]) {
        guard directories != watched else { return }
        if let old = stream {
            FSEventStreamStop(old)
            FSEventStreamInvalidate(old)
            FSEventStreamRelease(old)
            stream = nil
        }
        watched = directories
        guard !directories.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let agent = Unmanaged<Agent>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let flagList = (0..<count).map { flags[$0] }
            agent.handle(paths: list, flags: flagList)
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            log("could not watch \(directories)")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        log("watching \(directories.joined(separator: ", "))")
    }

    private func log(_ message: String) {
        print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    }
}
