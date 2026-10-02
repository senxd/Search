import Darwin

// Benchmark-only diagnostics. Keep normal SIGTERM behavior.
// ponytail: best-effort Swift signal diagnostic; use C if strict async-signal safety is required.
enum BenchmarkSignals {
    static func install() {
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = { number, info, _ in
            let prefix: StaticString = "[benchmark] SIGTERM sender="
            _ = write(STDERR_FILENO, prefix.utf8Start, prefix.utf8CodeUnitCount)
            var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            var sender = UInt32(max(0, info?.pointee.si_pid ?? 0))
            withUnsafeMutableBytes(of: &digits) { bytes in
                var index = bytes.count
                repeat {
                    index -= 1
                    bytes[index] = UInt8(sender % 10) + 48
                    sender /= 10
                } while sender > 0
                _ = write(STDERR_FILENO, bytes.baseAddress!.advanced(by: index), bytes.count - index)
            }
            let newline: StaticString = "\n"
            _ = write(STDERR_FILENO, newline.utf8Start, 1)
            _ = Darwin.signal(number, SIG_DFL)
            _ = kill(getpid(), number)
        }
        action.sa_flags = SA_SIGINFO
        sigemptyset(&action.sa_mask)
        _ = sigaction(SIGTERM, &action, nil)
    }
}
