import Foundation

/// Spotlight's processes as `fs_usage` names them.
public let spotlightProcesses: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared"]

/// Parses one `fs_usage -w` line into the path touched and the process name (without its pid).
/// Example: `22:57:01.12  open  F=5  (R_____)  /Volumes/T7 Shield/x/a.js   0.000012   mdworker_shared.4242`
/// Paths may contain single spaces; columns are separated by two or more. Paged-I/O lines put the
/// device first (`/dev/disk4s1  /Volumes/…`): the file path is what follows; device-only lines are dropped.
public func parseFsUsageLine(_ line: Substring) -> (path: String, process: String)? {
    guard let match = line.firstMatch(of: #/\s(/.*?)\s{2,}\d+\.\d+\s+(?:W\s+)?(\S+)\.\d+\s*$/#) else { return nil }
    var path = match.1
    if let device = path.wholeMatch(of: #//dev/\S+\s{2,}(/.*)/#) { path = device.1 }
    if path.wholeMatch(of: #/\/dev\/disk\S*/#) != nil { return nil }
    return (String(path), String(match.2))
}

/// Groups a path at a level a human can act on: the junk folder if the path is inside one,
/// else `depthBelowRoot` levels below its dev root (e.g. org/project/data/cache), else the first
/// `fallbackDepth` components.
public func bucket(_ path: String, ruleNames: Set<String>, roots: [String], depthBelowRoot: Int = 4, fallbackDepth: Int = 4) -> String {
    let components = path.split(separator: "/").map(String.init)
    if let junk = components.firstIndex(where: ruleNames.contains) {
        return "/" + components[...junk].joined(separator: "/")
    }
    if let root = roots.filter({ isWithin(path, $0) }).max(by: { $0.count < $1.count }) {
        let depth = root.split(separator: "/").count + depthBelowRoot
        return "/" + components.prefix(depth).joined(separator: "/")
    }
    return "/" + components.prefix(fallbackDepth).joined(separator: "/")
}

/// Busiest buckets first: (bucket, events) for Spotlight processes only.
public func rankSpotlightActivity(_ log: String, ruleNames: Set<String>, roots: [String], depthBelowRoot: Int = 4) -> [(bucket: String, events: Int)] {
    var counts: [String: Int] = [:]
    for line in log.split(separator: "\n") {
        guard let (path, process) = parseFsUsageLine(line), spotlightProcesses.contains(process) else { continue }
        counts[bucket(path, ruleNames: ruleNames, roots: roots, depthBelowRoot: depthBelowRoot), default: 0] += 1
    }
    return counts.map { ($0.key, $0.value) }.sorted { $0.events != $1.events ? $0.events > $1.events : $0.bucket < $1.bucket }
}
