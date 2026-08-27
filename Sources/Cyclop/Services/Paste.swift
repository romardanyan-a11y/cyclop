import AppKit
import ApplicationServices

/// Вставка выбранного прямо туда, где стоит курсор ввода в чужом окне.
///
/// Единственная возможность этого приложения, которая просит разрешение, — и
/// поэтому выключена по умолчанию и включается вручную. Синтетическое нажатие
/// ⌘V система пропускает только доверенным процессам: недоверенный вызов
/// `CGEvent.post` не падает и не жалуется, он просто ничего не делает, что для
/// пользователя выглядит как сломанная кнопка. Отсюда проверка перед каждой
/// отправкой, а не однажды при запуске: доверие снимают в системных настройках
/// в любой момент.
enum Paste {
    /// Доверен ли процесс настолько, чтобы его нажатия принимали всерьёз.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Спросить разрешение — открывает системный диалог со ссылкой в
    /// настройки. Возвращает уже выданное доверие; свежевыданное придёт позже,
    /// когда пользователь щёлкнет переключатель в системных настройках.
    @discardableResult
    static func requestPermission() -> Bool {
        // Ключ записан строкой, а не константой `kAXTrustedCheckOptionPrompt`:
        // константа импортируется в Swift как Unmanaged и требует возни с
        // takeUnretainedValue, а значение у неё — ровно эта строка.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Послать ⌘V.
    ///
    /// Отправлять можно только после того, как панель ушла с экрана и вернула
    /// ключ: пока ключевое окно наше, вставка прилетела бы в него самого.
    static func send() {
        guard isPermitted else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        // 9 — физическая клавиша V. Раскладка не важна: на кириллице там «м»,
        // и по символу совпадения не было бы.
        let key: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
