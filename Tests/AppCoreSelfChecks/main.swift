import AppCore
import Darwin
import Foundation

@main
struct AppCoreSelfCheckRunner {
    static func main() async {
        do {
            #if DEBUG
            try await AppCoreSelfChecks.run()
            print("AppCore self-checks passed.")
            #else
            print("AppCore self-checks are only compiled for debug builds.")
            #endif
        } catch {
            let message = "AppCore self-checks failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }
}
