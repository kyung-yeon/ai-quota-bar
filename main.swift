import AppKit
import Darwin

func argument(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

signal(SIGPIPE, SIG_IGN)
L10n.languageOverride = argument(after: "--language")
if CommandLine.arguments.contains("--help") {
    print("""
    AiQuotaBar — usage and persistent completion alerts
      --install-completion-hooks codex|claude  Back up and connect this CLI profile
      --remove-completion-hooks codex|claude   Remove only AiQuotaBar hooks
      --completion-hook codex|claude          Read one lifecycle event from stdin
      --notify-codex JSON                     Handle agent-turn-complete notify payload
      --run-herdr [--session NAME]            Attach Herdr and remember this terminal
      --self-test                            Run offline tests
      --preview-completions FILE             Render a sample notification panel
    """)
} else if CommandLine.arguments.contains("--install-completion-hooks") || CommandLine.arguments.contains("--remove-completion-hooks") {
    let remove = CommandLine.arguments.contains("--remove-completion-hooks")
    guard let name = argument(after: remove ? "--remove-completion-hooks" : "--install-completion-hooks"), let provider = Provider(rawValue: name), let executable = Bundle.main.executableURL?.path else { exit(64) }
    do {
        try HookInstaller.install(provider, executable: executable, remove: remove)
        try HookInstaller.setAutomaticConnection(!remove, configuration: HookInstaller.configurationURL(provider))
        print(HookInstaller.configurationURL(provider).path)
        if !remove { print(L10n.text("새 세션을 시작하세요. Codex는 /hooks에서 추가된 항목을 검토하고 신뢰해야 합니다.", "Start a new session. In Codex, review and trust the added entries in /hooks.")) }
    } catch { fputs("AiQuotaBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--run-herdr") {
    do { try HerdrClientBinding.attach(arguments: Array(CommandLine.arguments.dropFirst(index + 1))) }
    catch { fputs("AiQuotaBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--completion-hook") {
    guard let providerName = argument(after: "--completion-hook"), let provider = Provider(rawValue: providerName) else { fputs("Expected codex or claude\n", stderr); exit(64) }
    // Run before AppKit and the single-instance guard: hooks must also work while the app is closed.
    do {
        var data = Data()
        while data.count <= 1_048_576, let part = try FileHandle.standardInput.read(upToCount: min(8192, 1_048_577 - data.count)), !part.isEmpty { data.append(part) }
        let env = SessionCommand.hookEnvironment()
        let store = argument(after: "--completion-data-dir").map { CompletionStore(directory: URL(fileURLWithPath: $0)) } ?? .standard
        try store.receive(data, provider: provider, environment: env)
        print("{}")
    } catch { fputs("AiQuotaBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--notify-codex") {
    guard let payload = argument(after: "--notify-codex") else { exit(64) }
    do {
        let env = SessionCommand.hookEnvironment()
        let store = argument(after: "--completion-data-dir").map { CompletionStore(directory: URL(fileURLWithPath: $0)) } ?? .standard
        try store.receive(Data(payload.utf8), provider: .codex, environment: env)
    } catch { fputs("AiQuotaBar: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    do { try selfTest(); try completionTests(); try sessionTests(); try sessionHierarchyTests(); try progressTests(); try messageTests(); try navigationTests() } catch { fputs("\(error)\n", stderr); exit(1) }
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
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--completion-ui-test") {
        do { try completionUITests() } catch { fputs("\(error)\n", stderr); exit(1) }
    } else if let path = argument(after: "--preview-completions") {
        Preview.completions(path: path)
    } else if CommandLine.arguments.contains("--preview-demo"), let path = argument(after: "--preview") {
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
}
