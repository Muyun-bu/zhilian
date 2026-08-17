import AppKit
import Foundation

/// Requests a normal AppKit termination so lifecycle tests exercise the same
/// proxy restoration path as Command-Q instead of killing the process.
@main
struct TerminateApplicationForTest {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let pid = Int32(CommandLine.arguments[1]),
              let application = NSRunningApplication(processIdentifier: pid) else {
            fputs("usage: TerminateApplicationForTest <pid>\n", stderr)
            exit(64)
        }
        guard application.terminate() else {
            fputs("application rejected termination\n", stderr)
            exit(1)
        }
        print("terminate-requested")
    }
}
