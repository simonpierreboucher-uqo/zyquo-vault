import SwiftUI
import ZyquoVaultDesign

/// Root state machine: welcome → create / locked → unlocked. The unlock moment
/// is the app's one theatrical animation (§3.2): the content settles in with a
/// gentle spring — replaced by a plain fade under Reduce Motion.
public struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            Zyquo.color.canvas.ignoresSafeArea()
            switch model.screen {
            case .loading:
                ProgressView()
            case .welcome:
                WelcomeView(model: model)
            case .locked:
                LockScreenView(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
            case .unlocked:
                MainWindowView(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Zyquo.motion.spring, value: model.screen)
        .frame(minWidth: 640, minHeight: 560)
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear { model.bootstrap() }
    }
}
