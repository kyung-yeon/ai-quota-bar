import Foundation
import CryptoKit

enum CompletionError: Error, LocalizedError {
    case invalidEvent, busy, unavailable, unsupported, corruptStore
    var errorDescription: String? {
        switch self {
        case .invalidEvent: return L10n.text("완료 이벤트 형식을 확인해 주세요.", "Invalid completion event.")
        case .busy: return L10n.text("잠시 후 다시 시도해 주세요.", "Please try again shortly.")
        case .unavailable: return L10n.text("원래 세션으로 이동하지 못했습니다. 앱·탭이 열려 있는지와 자동화 권한을 확인해 주세요.", "Could not open the original session. Check that its app and tab are open and automation is allowed.")
        case .unsupported: return L10n.text("이 환경의 탭으로 바로 이동할 수 없습니다. 세션 재개 명령을 복사해 사용해 주세요.", "Direct navigation is unavailable for this environment. Copy the resume command instead.")
        case .corruptStore: return L10n.text("알림 저장 파일을 읽지 못했습니다. 기존 파일은 보존했습니다.", "Cannot read the notification store. The existing file has been preserved.")
        }
    }
}

func completionHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct CompletionEvent: Codable, Equatable, Identifiable {
    let id: String
    let providerID: String
    let sessionID: String
    let project: String
    let directory: String
    let sessionName: String
    let completedAt: Date
    var destination: SessionDestination
    var acknowledgedAt: Date?
    var provider: Provider { Provider(rawValue: providerID) ?? .codex }

    /// Accept only main-agent response completion, never session exit or child-agent exit.
    /// Keep identifiers and display metadata; do not persist prompts or assistant responses.
    static func decode(_ data: Data, provider: Provider, environment: [String: String], now: Date = Date(), fallbackToken: String? = nil) throws -> CompletionEvent? {
        guard data.count <= 1_048_576,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompletionError.invalidEvent }
        let notify = provider == .codex && payload["type"] as? String == "agent-turn-complete"
        guard notify || payload["hook_event_name"] as? String == "Stop" else { return nil }
        guard let session = payload[notify ? "thread-id" : "session_id"] as? String, validID(session),
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else { throw CompletionError.invalidEvent }
        // Older Claude releases use the token recorded by UserPromptSubmit.
        let turn = (payload[notify ? "turn-id" : "turn_id"] as? String)
            ?? (payload["prompt_id"] as? String)
            ?? fallbackToken
            ?? fallbackTurn(payload)
        guard validID(turn) else { throw CompletionError.invalidEvent }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let name = environment["AIQUOTABAR_SESSION_NAME"] ?? payload["session_name"] as? String
        return CompletionEvent(id: completionHash("\(provider.rawValue)\u{0}\(session)\u{0}\(turn)"),
            providerID: provider.rawValue, sessionID: session, project: String(project.prefix(100)), directory: cwd,
            sessionName: String((name?.isEmpty == false ? name! : String(session.prefix(12))).prefix(120)),
            completedAt: now, destination: .capture(environment: environment))
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func fallbackTurn(_ payload: [String: Any]) -> String {
        // A compatibility fallback only; replay of the same response is intentionally collapsed.
        completionHash((payload["last_assistant_message"] as? String ?? "") + "\u{0}" + (payload["last-assistant-message"] as? String ?? ""))
    }
}

enum TerminalHost: String, Codable {
    case terminal, iterm, warp, cmux, orca, wezterm, kitty, unsupported
    var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .warp: return "Warp"
        case .cmux: return "cmux"
        case .orca: return "Orca"
        case .wezterm: return "WezTerm"
        case .kitty: return "kitty"
        case .unsupported: return L10n.text("세션", "Session")
        }
    }
}

struct HerdrDestination: Codable, Equatable {
    let pane: String
    let socket: String
}

struct SessionDestination: Codable, Equatable {
    var host: TerminalHost = .unsupported
    var target: String = ""
    var workspace: String?
    var socket: String?
    var herdr: HerdrDestination?
    var label: String { herdr == nil ? host.name : "Herdr · \(host.name)" }

    static func capture(environment env: [String: String]) -> SessionDestination {
        var result = SessionDestination()
        // A daemon/multiplexer can retain the first client's environment. Never guess its current tab.
        guard env["TMUX"] == nil, env["STY"] == nil, env["SSH_CONNECTION"] == nil else { return result }
        if let pane = env["HERDR_PANE_ID"], let socket = env["HERDR_SOCKET_PATH"] {
            result.herdr = HerdrDestination(pane: pane, socket: socket)
        }
        if let surface = env["CMUX_SURFACE_ID"], let workspace = env["CMUX_WORKSPACE_ID"] {
            result.host = .cmux; result.target = surface; result.workspace = workspace
        } else if let handle = env["ORCA_TERMINAL_HANDLE"] {
            result.host = .orca; result.target = handle
        } else if let id = env["ITERM_SESSION_ID"] {
            result.host = .iterm; result.target = id
        } else if let url = env["WARP_FOCUS_URL"] {
            result.host = .warp; result.target = url
        } else if let pane = env["WEZTERM_PANE"] {
            result.host = .wezterm; result.target = pane; result.socket = env["WEZTERM_UNIX_SOCKET"]
        } else if let pane = env["KITTY_WINDOW_ID"], let socket = env["KITTY_LISTEN_ON"] {
            result.host = .kitty; result.target = pane; result.socket = socket
        } else if env["TERM_PROGRAM"] == "Apple_Terminal", let tty = env["AIQUOTABAR_TTY"] {
            result.host = .terminal; result.target = tty
        }
        return result
    }
}
