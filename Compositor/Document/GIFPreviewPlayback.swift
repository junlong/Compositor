import Foundation

/// Preview presentation follows elapsed time; decoding never changes the saved frame delays.
enum GIFPreviewPlayback {

    static func play(durations: [TimeInterval], startingAt initial: Int, loops: Bool = true,
                     showFrame: (Int) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard durations.count > 1, durations.indices.contains(initial),
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        let total = durations.reduce(0, +)
        guard total.isFinite, total < Double(Int64.max) else { return }

        var starts: [TimeInterval] = [], running: TimeInterval = 0
        for duration in durations {
            starts.append(running)
            running += duration
        }

        let offset = starts[initial]
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
        func wait(until deadline: TimeInterval) async throws {
            let remaining = deadline - elapsed()
            // A deadline already passed falls straight through: late frames catch up on the next iteration.
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }

        var displayed = initial
        var next = durations[initial]
        while true {
            try await wait(until: next)
            try Task.checkCancellation()
            let position = offset + elapsed()
            if !loops, position >= total {
                // Once always ends on the last frame, even if decoding missed its interval.
                if displayed != durations.count - 1 { try await showFrame(durations.count - 1) }
                try Task.checkCancellation()
                return
            }
            var time = position.truncatingRemainder(dividingBy: total)
            if time < 0 || time >= total { time = 0 }
            var lower = 0, upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] <= time { lower = middle + 1 }
                else { upper = middle }
            }
            let index = max(0, lower - 1)
            let end = index + 1 < starts.count ? starts[index + 1] : total
            // Keep the boundary sampled before decoding. Late frames catch up on the next iteration.
            next = elapsed() + end - time
            if index != displayed {
                try await showFrame(index)
                try Task.checkCancellation()
                displayed = index
            }
        }
    }
}
