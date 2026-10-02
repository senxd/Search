import Darwin
import Foundation

@main
struct SignalCheck {
    static func main() throws {
        if CommandLine.arguments.contains("--child") {
            BenchmarkSignals.install()
            var ready: UInt8 = 1
            _ = write(STDOUT_FILENO, &ready, 1)
            while true { pause() }
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--child"]
        let output = Pipe(), ready = Pipe()
        child.standardError = output
        child.standardOutput = ready
        try child.run()
        precondition(ready.fileHandleForReading.readData(ofLength: 1).count == 1)
        child.terminate()
        child.waitUntilExit()
        precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM,
                     "handler must preserve signal termination")
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(message == "[benchmark] SIGTERM sender=\(getpid())\n", message)
        print("PASS benchmark SIGTERM sender diagnostics and normal termination")
    }
}
