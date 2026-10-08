import Foundation

/// «Не засыпать с закрытой крышкой» — системный запрет сна, `pmset disablesleep`.
///
/// Мягче не выходит. Утверждения IOKit — то, чем держат мак бодрым caffeinate
/// и Amphetamine без своего помощника, — работают, пока крышка открыта: её
/// закрытие усыпляет мак поверх любого из них, если не подключён внешний
/// монитор. Запрет сна — настройка самой системы, и менять её может только
/// администратор, поэтому каждое переключение спрашивает пароль.
///
/// Источник правды — система, а не настройки приложения. Запрет переживает и
/// выход из Cyclop, и перезагрузку, поэтому галочка показывает то, что
/// включено на самом деле, а не то, что нажимали в прошлый раз.
@MainActor
final class LidSleep: ObservableObject {
    static let shared = LidSleep()

    /// Сон запрещён — мак не уснёт ни сам, ни от закрытой крышки.
    @Published private(set) var isDisabled = false
    /// Ждём пароль или pmset. Галочка в это время не нажимается, иначе второй
    /// запрос пароля встал бы в очередь за первым.
    @Published private(set) var isBusy = false

    private init() {}

    /// Прочитать запрет из системы. Не спрашивает пароль: `pmset -g` доступен всем.
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let disabled = Self.readSleepDisabled()
            DispatchQueue.main.async { [weak self] in self?.isDisabled = disabled }
        }
    }

    func set(_ disabled: Bool) {
        guard !isBusy, disabled != isDisabled else { return }
        isBusy = true
        // Свой текст в окне пароля: без него система пишет «osascript хочет
        // внести изменения», и непонятно, кто и зачем просит.
        let prompt = disabled
            ? localized("Cyclop wants to keep this Mac awake with the lid closed.")
            : localized("Cyclop wants to let this Mac sleep again.")
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let script = "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            // Отказ от пароля — не ошибка, а ответ. Что бы ни случилось,
            // галочка встаёт по тому, что в итоге записано в системе.
            Self.run("/usr/bin/osascript", ["-e", script])
            let result = Self.readSleepDisabled()
            DispatchQueue.main.async { [weak self] in
                self?.isDisabled = result
                self?.isBusy = false
            }
        }
    }

    /// `pmset -g` печатает запрет первой строкой под «System-wide power
    /// settings» — ` SleepDisabled  1`. Снятый запрет не печатается вовсе.
    nonisolated private static func readSleepDisabled() -> Bool {
        guard let output = run("/usr/bin/pmset", ["-g"]) else { return false }
        return output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
