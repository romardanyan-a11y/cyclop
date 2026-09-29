import AppKit
import WebKit

/// Яндекс Переводчик — сам сайт, в одном веб-виде на всё приложение.
///
/// Переводит страница, а не мы. Режим «Переводчик AI» у неё включён по
/// умолчанию, и переключатель под полем ввода сайт запоминает сам — в своём
/// хранилище, которое здесь лежит на диске. Поэтому отсюда перевод никто не
/// ведёт: страница только живёт между открытиями панели и получает клавиатуру.
///
/// API у «Переводчика AI» нет: у Яндекс Облака свой перевод, классический, а
/// режим с языковой моделью есть только на сайте и в приложениях.
@MainActor
final class Translator: NSObject, ObservableObject {
    static let home = URL(string: "https://translate.yandex.ru/")!

    /// Телефонная вёрстка. Настольная раскладывает две колонки рядом только
    /// в окне шире тысячи точек, а уже — ставит их друг под другом, и поле
    /// ввода одно занимает всю панель, выталкивая перевод за нижний край.
    /// Телефонная сделана ровно под такой размер: поле, переключатель модели
    /// и перевод помещаются в высокую панель целиком.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Страница не загрузилась: нет сети или сайт не ответил.
    @Published private(set) var failed = false

    /// Создаётся при первом открытии вкладки, а не при запуске: веб-вид — это
    /// отдельный процесс WebKit, и до этой вкладки доходит не каждый запуск.
    private(set) lazy var webView: TranslatorWebView = makeWebView()

    /// Курсор просили в поле, пока страница ещё грузилась. Ставится, когда
    /// она догрузится: раньше поля в документе нет.
    private var focusPending = false

    private func makeWebView() -> TranslatorWebView {
        let configuration = WKWebViewConfiguration()
        // Хранилище на диске: настройки самого сайта — модель перевода,
        // закрытое приветствие, вход в Яндекс ID — переживают перезапуск.
        configuration.websiteDataStore = .default()
        let view = TranslatorWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = Self.userAgent
        // Панель тёмная, и до первой отрисовки страницы на её месте должен
        // быть чёрный, а не белый прямоугольник. Саму страницу в тёмную тему
        // переводит внешний вид окна: у сайта по умолчанию тема «как в системе».
        view.underPageBackgroundColor = .black
        view.navigationDelegate = self
        view.uiDelegate = self
        view.load(URLRequest(url: Self.home))
        return view
    }

    func reload() {
        failed = false
        if webView.url == nil {
            webView.load(URLRequest(url: Self.home))
        } else {
            webView.reload()
        }
    }

    /// Курсор в поле ввода. `#textarea` — поле телефонной вёрстки,
    /// `#fakeArea` — настольной, на случай если сайт отдаст её.
    func focusInput() {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        guard !webView.isLoading else {
            focusPending = true
            return
        }
        webView.evaluateJavaScript(
            "(document.querySelector('#textarea') || document.querySelector('#fakeArea'))?.focus()",
            completionHandler: nil
        )
    }

    func resignInput() {
        focusPending = false
        guard let window = webView.window,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: webView) else { return }
        window.makeFirstResponder(nil)
    }

    /// Ссылка ведёт на сам переводчик или на вход в Яндекс ID. Остальное —
    /// справка, соцсети, другие сервисы — открывается в браузере: в панели
    /// у страницы нет кнопки «назад», и уйдя с переводчика, на него не вернуться.
    private static func staysInPanel(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return host.hasPrefix("translate.yandex.") || host.hasPrefix("passport.yandex.")
    }
}

extension Translator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // Только клики по ссылкам. Перенаправления пропускаются все: вход в
        // Яндекс ID идёт через цепочку чужих адресов и обрывается на первом же.
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              !Self.staysInPanel(url) else { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failed = false
        if focusPending {
            focusPending = false
            focusInput()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        noteFailure(error)
    }

    /// Процесс страницы система снимает при нехватке памяти, и веб-вид
    /// остаётся пустым. Загрузить заново — всё, что тут можно сделать.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func noteFailure(_ error: Error) {
        // Отменённая загрузка — это новая, начатая поверх, а не сбой.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        failed = true
    }
}

extension Translator: WKUIDelegate {
    /// Ссылки в новом окне: окон у панели нет, так что либо сюда же, либо в браузер.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Self.staysInPanel(url) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    /// Голосовой ввод выключен: микрофон приложению не нужен ни для чего
    /// другого, и спрашивать о нём ради одной кнопки на сайте незачем.
    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }
}

/// Веб-вид, у которого Esc отдаёт клавиатуру обратно, как в заметках.
/// Остальные клавиши — странице.
final class TranslatorWebView: WKWebView {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }
}
