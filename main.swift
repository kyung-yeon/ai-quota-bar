import AppKit
import Darwin

func argument(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

signal(SIGPIPE, SIG_IGN)
L10n.languageOverride = argument(after: "--language")
if CommandLine.arguments.contains("--self-test") {
    do { try selfTest(); try completionTests() } catch { fputs("\(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--check") {
    Task.detached {
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderFailure>).self) { group in
            for provider in Provider.allCases { group.addTask { (provider, await ProviderClient.fetch(provider)) } }
            for await (provider, result) in group {
                switch result {
                case .success(let value):
                    print("\(provider.name):")
                    for window in value.windows {
                        print("  \(window.label): \(window.remaining)% · \(window.resetsAt.map { dateText($0) } ?? "—")")
                    }
                    if let credits = value.resetCredits {
                        print("  \(L10n.text("초기화권", "Reset passes")): \(credits.availableCount)")
                        for credit in credits.availableDetails(at: Date()) { print("  \(creditExpiryText(credit))") }
                    } else { print("  \(L10n.text("초기화권 정보 제공 안 됨", "Reset passes unavailable"))") }
                case .failure(let error): print("\(provider.name): \(error.localizedDescription)")
                }
            }
        }
        exit(0)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--preview-demo"), let path = argument(after: "--preview") {
        Preview.write(states: Preview.sampleStates(), path: path)
    } else {
        // Reopening the installed application must not create a duplicate menu bar item.
        if !CommandLine.arguments.contains("--smoke-test"), let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { exit(0) }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
