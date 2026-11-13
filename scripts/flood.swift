// Log flood for throughput checks: writes `rate` messages per second through os.Logger,
// spread over `threads` threads, for `seconds` seconds. Run via scripts/flood.sh.
//
//   flood [rate=25000] [seconds=60] [threads=4] [level=debug|info|default]
import Foundation
import os

let args = CommandLine.arguments
let rate = args.count > 1 ? Int(args[1]) ?? 25_000 : 25_000
let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60
let threads = args.count > 3 ? Int(args[3]) ?? 4 : 4
let level: OSLogType = switch args.count > 4 ? args[4] : "debug" {
case "info": .info
case "default": .default
default: .debug
}

let categories = ["network", "storage", "ui", "sync", "auth", "cache", "render", "io"]
let fillers = [
    "short",
    "request finished with status 200 in 12 ms",
    "lookupHandle state=0x7c4 handle=<private> flags=[sync, retry] attempt 3 of 5",
    String(repeating: "lorem ipsum dolor sit amet ", count: 8),
]
let perThread = Double(rate) / Double(threads)
let batch = 50
let deadline = Date().addingTimeInterval(seconds)
let sent = OSAllocatedUnfairLock(initialState: 0)
let group = DispatchGroup()

for t in 0..<threads {
    let logger = Logger(subsystem: "app.betterconsole.flood", category: categories[t % categories.count])
    group.enter()
    Thread.detachNewThread {
        let start = Date()
        var n = 0
        while Date() < deadline {
            for _ in 0..<batch {
                let filler = fillers[n % fillers.count]
                logger.log(level: level, "flood t\(t, privacy: .public) #\(n, privacy: .public) \(filler, privacy: .public)")
                n += 1
            }
            // Keep to the schedule: thread `t` should have sent `perThread * elapsed`.
            let due = Double(n) / perThread
            let ahead = due - Date().timeIntervalSince(start)
            if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
        }
        let count = n
        sent.withLock { $0 += count }
        group.leave()
    }
}
group.wait()
let total = sent.withLock { $0 }
print("flood: sent \(total) messages in \(Int(seconds)) s (\(Int(Double(total) / seconds)) msg/s, target \(rate))")
