import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeyManager {
    enum Action: UInt32, CaseIterable {
        case togglePanel = 1
        case deepAnalyze = 2
        case questionCandidates = 3
        case answerCandidate = 4

        var keyCode: UInt32 {
            switch self {
            case .togglePanel: UInt32(kVK_Space)
            case .deepAnalyze: UInt32(kVK_ANSI_D)
            case .questionCandidates: UInt32(kVK_ANSI_Q)
            case .answerCandidate: UInt32(kVK_ANSI_A)
            }
        }

        var keyLabel: String {
            switch self {
            case .togglePanel: "Space"
            case .deepAnalyze: "D"
            case .questionCandidates: "Q"
            case .answerCandidate: "A"
            }
        }

        var settingsTitle: String {
            switch self {
            case .togglePanel: "サイドパネル表示／非表示"
            case .deepAnalyze: "今の話を深掘り"
            case .questionCandidates: "質問候補"
            case .answerCandidate: "回答候補"
            }
        }
    }

    private static let signature: OSType = 0x43_55_45_20 // CUE

    private var eventHandler: EventHandlerRef?
    private var hotKeyReferences: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]

    func install(
        configuration: GlobalShortcutConfiguration,
        handlers: [Action: () -> Void]
    ) -> [Action: OSStatus] {
        uninstall()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            cueHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            return Dictionary(
                uniqueKeysWithValues: Action.allCases.map { ($0, installStatus) }
            )
        }

        var failures: [Action: OSStatus] = [:]

        for action in Action.allCases {
            let choice = configuration.choice(for: action)
            guard let modifiers = choice.carbonModifiers,
                  let handler = handlers[action]
            else { continue }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: Self.signature,
                id: action.rawValue
            )
            let status = RegisterEventHotKey(
                action.keyCode,
                modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeyReferences.append(reference)
                actions[action.rawValue] = handler
            } else {
                failures[action] = status
            }
        }
        return failures
    }

    func uninstall() {
        hotKeyReferences.forEach { UnregisterEventHotKey($0) }
        hotKeyReferences.removeAll()
        actions.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func handle(identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == Self.signature,
              let action = actions[identifier.id]
        else { return OSStatus(eventNotHandledErr) }
        action()
        return noErr
    }
}

enum ShortcutModifierChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case option
    case controlOption
    case commandOption
    case controlCommand
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: "Option"
        case .controlOption: "Control + Option"
        case .commandOption: "Command + Option"
        case .controlCommand: "Control + Command"
        case .disabled: "無効"
        }
    }

    var displayPrefix: String {
        switch self {
        case .option: "⌥"
        case .controlOption: "⌃⌥"
        case .commandOption: "⌘⌥"
        case .controlCommand: "⌃⌘"
        case .disabled: ""
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .option: UInt32(optionKey)
        case .controlOption: UInt32(controlKey | optionKey)
        case .commandOption: UInt32(cmdKey | optionKey)
        case .controlCommand: UInt32(controlKey | cmdKey)
        case .disabled: nil
        }
    }
}

struct GlobalShortcutConfiguration: Codable, Equatable, Sendable {
    var togglePanel: ShortcutModifierChoice = .option
    var deepAnalyze: ShortcutModifierChoice = .option
    var questionCandidates: ShortcutModifierChoice = .option
    var answerCandidate: ShortcutModifierChoice = .option

    static let storageKey = "globalShortcutConfiguration.v1"

    func choice(for action: GlobalHotKeyManager.Action) -> ShortcutModifierChoice {
        switch action {
        case .togglePanel: togglePanel
        case .deepAnalyze: deepAnalyze
        case .questionCandidates: questionCandidates
        case .answerCandidate: answerCandidate
        }
    }

    mutating func setChoice(
        _ choice: ShortcutModifierChoice,
        for action: GlobalHotKeyManager.Action
    ) {
        switch action {
        case .togglePanel: togglePanel = choice
        case .deepAnalyze: deepAnalyze = choice
        case .questionCandidates: questionCandidates = choice
        case .answerCandidate: answerCandidate = choice
        }
    }

    func label(for action: GlobalHotKeyManager.Action) -> String {
        let choice = choice(for: action)
        guard choice != .disabled else { return "無効" }
        return "\(choice.displayPrefix)\(action.keyLabel)"
    }

    var enabledCount: Int {
        GlobalHotKeyManager.Action.allCases.count {
            choice(for: $0) != .disabled
        }
    }

    static func load(
        defaults: UserDefaults = .standard
    ) -> GlobalShortcutConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

private func cueHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<GlobalHotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        manager.handle(identifier: identifier)
    }
}
