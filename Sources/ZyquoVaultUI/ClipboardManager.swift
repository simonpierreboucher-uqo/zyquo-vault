import AppKit
import Observation
import SwiftUI
import ZyquoVaultDesign

/// Clipboard service (§10.7): write → fingerprint → countdown → clear only if
/// the clipboard still holds the same value → also clear on lock. Never logs
/// contents. Publishes the remaining seconds for the countdown chip.
@MainActor
@Observable
public final class ClipboardManager {

    /// User-selectable clearing window; `nil` = never (explicit opt-out).
    public var clearAfterSeconds: Int? {
        didSet { UserDefaults.standard.set(clearAfterSeconds ?? -1, forKey: Self.defaultsKey) }
    }
    public static let options: [Int?] = [10, 30, 60, 120, nil]
    static let defaultsKey = "clipboardClearSeconds"

    /// Seconds until the owned value is cleared (drives the chip); nil = idle.
    public private(set) var secondsRemaining: Int?

    private var ownedChangeCount: Int?
    private var countdownTask: Task<Void, Never>?

    public init() {
        let stored = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Int
        self.clearAfterSeconds = switch stored {
        case nil: 30          // secure default
        case -1: nil          // "never"
        case let value?: value
        }
    }

    /// Copies a secret with transient/concealed pasteboard hints and starts the
    /// countdown.
    public func copySecret(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString(value, forType: .string)
        ownedChangeCount = pasteboard.changeCount
        startCountdown()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        guard let total = clearAfterSeconds else {
            secondsRemaining = nil
            return
        }
        secondsRemaining = total
        countdownTask = Task { [weak self] in
            var remaining = total
            while remaining > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
                self?.secondsRemaining = remaining
                // Someone else took the clipboard: our value is gone, stand down.
                if let owned = self?.ownedChangeCount,
                   NSPasteboard.general.changeCount != owned {
                    self?.stopOwning()
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.clearIfOwned()
        }
    }

    /// Clears the pasteboard only when it still holds the value we put there.
    public func clearIfOwned() {
        if let owned = ownedChangeCount, NSPasteboard.general.changeCount == owned {
            NSPasteboard.general.clearContents()
        }
        stopOwning()
    }

    private func stopOwning() {
        countdownTask?.cancel()
        countdownTask = nil
        ownedChangeCount = nil
        secondsRemaining = nil
    }
}

/// Countdown chip (§10.7): "Clears in 27 s", shown after copying a secret.
struct ClipboardChip: View {
    let manager: ClipboardManager

    var body: some View {
        if let seconds = manager.secondsRemaining {
            HStack(spacing: Zyquo.spacing.xxs) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10))
                Text("Clears in \(seconds) s")
                    .font(Zyquo.type.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(Zyquo.color.accent)
            .padding(.vertical, Zyquo.spacing.xxs)
            .padding(.horizontal, Zyquo.spacing.xs)
            .background(Capsule(style: .continuous).fill(Zyquo.color.accentSoft))
            .transition(.opacity)
            .accessibilityLabel("Clipboard clears in \(seconds) seconds")
        }
    }
}
