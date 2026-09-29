import SwiftUI
import WebKit

/// Яндекс Переводчик в режиме «Переводчик AI» — страница сайта целиком.
/// Что она умеет и почему телефонная, см. `Translator`.
struct TranslatePane: View {
    @ObservedObject var translator: Translator
    /// Whether the panel holds the keyboard. Drops to false when the user
    /// clicks into another app, and the page follows it — the caret has to
    /// stop blinking here when it has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool

    var body: some View {
        ZStack {
            WebHost(translator: translator, wantsKeyboard: $wantsKeyboard)
            if translator.failed {
                failure
            }
        }
        .padding(.top, 2)
    }

    private var failure: some View {
        VStack(spacing: 8) {
            Text("Yandex Translate did not load.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Button("Retry") { translator.reload() }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// Держит единственный веб-вид переводчика.
///
/// Через свой контейнер, а не отдавая SwiftUI веб-вид напрямую: панель строится
/// на каждом экране своя, а у вида может быть только один родитель. Веб-вид
/// забирает к себе та панель, что построена последней, — это та, над которой
/// курсор; брошенный контейнер остаётся пустым и уходит вместе со своей панелью.
private struct WebHost: NSViewRepresentable {
    let translator: Translator
    @Binding var wantsKeyboard: Bool

    final class Coordinator {
        /// Последнее, что делали с фокусом. Обновления вида приходят и без
        /// смены клавиатуры, а вернуть курсор в поле на каждом из них значило
        /// бы выдёргивать его оттуда, где пользователь выделяет перевод.
        var applied: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        let web = translator.webView
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        translator.webView.onEscape = { wantsKeyboard = false }

        let wants = wantsKeyboard
        guard context.coordinator.applied != wants else { return }
        context.coordinator.applied = wants
        if wants {
            // Только что созданный контейнер ещё не в окне, и сделать веб-вид
            // первым ответчиком не у кого. Проходом позже он уже там.
            DispatchQueue.main.async {
                guard wantsKeyboard else { return }
                translator.focusInput()
            }
        } else {
            // Сразу, а не проходом позже: панель складывается следующим
            // проходом после того, как отпустила клавиатуру, и фокус, снятый
            // посреди сворачивания, уносит с собой перерисовку (#44).
            translator.resignInput()
        }
    }
}
