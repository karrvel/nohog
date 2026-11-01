import Foundation

/// Seconds from a `ps -o time` value: "0:01.23", "61:02.50", "1:02:03.45" or "2-01:02:03.45".
public func parseCPUTime(_ text: Substring) -> Double? {
    var rest = text
    var days = 0.0
    if let dash = rest.firstIndex(of: "-") {
        guard let d = Double(rest[..<dash]) else { return nil }
        days = d
        rest = rest[rest.index(after: dash)...]
    }
    var seconds = 0.0
    for part in rest.split(separator: ":") {
        guard let value = Double(part) else { return nil }
        seconds = seconds * 60 + value
    }
    return days * 86_400 + seconds
}

/// Parses `ps -axo pid=,time=,comm=` into (pid, CPU seconds) for Spotlight's processes only.
public func spotlightCPU(fromPS output: String) -> [Int32: Double] {
    var result: [Int32: Double] = [:]
    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = Int32(fields[0]), let cpu = parseCPUTime(fields[1]) else { continue }
        let name = fields[2].split(separator: "/").last.map(String.init) ?? ""
        if spotlightProcesses.contains(name) { result[pid] = cpu }
    }
    return result
}

/// CPU used by Spotlight's processes between the first sample and the latest one. Workers that
/// start during the window count from zero. CPU a worker uses after its last sample before exiting
/// is missed, which is bounded by the sampling interval.
public struct CPUMeter: Sendable {
    private var first: [Int32: Double] = [:]
    private var last: [Int32: Double] = [:]

    public init(start: [Int32: Double]) {
        first = start
        last = start
    }

    public mutating func add(_ sample: [Int32: Double]) {
        for (pid, cpu) in sample {
            if first[pid] == nil { first[pid] = 0 }
            last[pid] = max(last[pid] ?? 0, cpu)
        }
    }

    public var total: Double {
        last.reduce(0) { $0 + max(0, $1.value - (first[$1.key] ?? 0)) }
    }
}

/// A plausible node_modules file: code plus a token that identifies the benchmark run in mdfind.
public func benchFileContents(index: Int, token: String) -> String {
    """
    // \(token) module-\(index)
    'use strict';
    Object.defineProperty(exports, "__esModule", { value: true });
    function resolvePackage\(index)(name, options) {
      const cache = new Map();
      if (cache.has(name)) return cache.get(name);
      const result = { name, version: "1.\(index % 50).\(index % 7)", main: "index.js", options };
      cache.set(name, result);
      return result;
    }
    exports.resolvePackage\(index) = resolvePackage\(index);
    /* Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt
       ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation. */

    """
}
