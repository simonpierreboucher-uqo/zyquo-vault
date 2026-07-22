import SwiftUI
import ZyquoVaultCrypto
import ZyquoVaultDesign

/// Password generator (§10.4): random / passphrase / PIN / pattern, CSPRNG with
/// rejection sampling, entropy shown as an estimate. Used from the item editor.
struct GeneratorPopover: View {
    enum Mode: String, CaseIterable {
        case random = "Random"
        case passphrase = "Passphrase"
        case pin = "PIN"
        case pattern = "Pattern"
    }

    let onUse: (String) -> Void

    @State private var mode: Mode = .random
    @State private var generated = ""
    // Random options
    @State private var length = 20.0
    @State private var useLower = true
    @State private var useUpper = true
    @State private var useDigits = true
    @State private var useSymbols = true
    @State private var excludeAmbiguous = false
    // Passphrase options
    @State private var wordCount = 5.0
    @State private var separator = "-"
    @State private var capitalize = false
    @State private var includeDigit = false
    // PIN / pattern
    @State private var pinLength = 6.0
    @State private var pattern = "Aaaa-9999-#aaa"

    var body: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            options

            Text(generated.isEmpty ? " " : generated)
                .font(Zyquo.type.mono)
                .foregroundStyle(Zyquo.color.inkPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Zyquo.spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                        .fill(Zyquo.color.surfaceSunken)
                )

            Text("≈\(Int(entropyEstimate)) bits (estimate)")
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkTertiary)

            HStack {
                ZyquoButton("Regenerate", role: .secondary, action: regenerate)
                Spacer()
                ZyquoButton("Use") {
                    if !generated.isEmpty { onUse(generated) }
                }
            }
        }
        .padding(Zyquo.spacing.l)
        .frame(width: 340)
        .background(Zyquo.color.canvas)
        .onAppear(perform: regenerate)
        .onChange(of: mode) { regenerate() }
        .onChange(of: length) { regenerate() }
        .onChange(of: useLower) { regenerate() }
        .onChange(of: useUpper) { regenerate() }
        .onChange(of: useDigits) { regenerate() }
        .onChange(of: useSymbols) { regenerate() }
        .onChange(of: excludeAmbiguous) { regenerate() }
        .onChange(of: wordCount) { regenerate() }
        .onChange(of: separator) { regenerate() }
        .onChange(of: capitalize) { regenerate() }
        .onChange(of: includeDigit) { regenerate() }
        .onChange(of: pinLength) { regenerate() }
        .onChange(of: pattern) { regenerate() }
    }

    @ViewBuilder
    private var options: some View {
        switch mode {
        case .random:
            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                HStack {
                    Text("Length: \(Int(length))")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                    Slider(value: $length, in: 8...64, step: 1)
                }
                HStack(spacing: Zyquo.spacing.s) {
                    Toggle("a–z", isOn: $useLower)
                    Toggle("A–Z", isOn: $useUpper)
                    Toggle("0–9", isOn: $useDigits)
                    Toggle("#!?", isOn: $useSymbols)
                }
                .toggleStyle(.checkbox)
                .font(Zyquo.type.caption)
                Toggle("Exclude ambiguous (Il1O0…)", isOn: $excludeAmbiguous)
                    .toggleStyle(.checkbox)
                    .font(Zyquo.type.caption)
            }
        case .passphrase:
            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                HStack {
                    Text("Words: \(Int(wordCount))")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                    Slider(value: $wordCount, in: 3...10, step: 1)
                }
                HStack(spacing: Zyquo.spacing.s) {
                    Picker("Separator", selection: $separator) {
                        Text("dash").tag("-")
                        Text("dot").tag(".")
                        Text("space").tag(" ")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle("Caps", isOn: $capitalize).toggleStyle(.checkbox).font(Zyquo.type.caption)
                    Toggle("Digit", isOn: $includeDigit).toggleStyle(.checkbox).font(Zyquo.type.caption)
                }
            }
        case .pin:
            HStack {
                Text("Digits: \(Int(pinLength))")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                Slider(value: $pinLength, in: 4...12, step: 1)
            }
        case .pattern:
            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                TextField("Pattern", text: $pattern)
                    .textFieldStyle(.plain)
                    .font(Zyquo.type.mono)
                    .padding(Zyquo.spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                            .fill(Zyquo.color.surfaceSunken)
                    )
                Text("a lowercase · A uppercase · 9 digit · # symbol · x any — other characters kept")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkTertiary)
            }
        }
    }

    private var classes: PasswordGenerator.CharacterClasses {
        var set: PasswordGenerator.CharacterClasses = []
        if useLower { set.insert(.lowercase) }
        if useUpper { set.insert(.uppercase) }
        if useDigits { set.insert(.digits) }
        if useSymbols { set.insert(.symbols) }
        return set
    }

    private var entropyEstimate: Double {
        switch mode {
        case .random:
            PasswordGenerator.randomPasswordEntropy(length: Int(length), classes: classes, excludeAmbiguous: excludeAmbiguous)
        case .passphrase:
            PasswordGenerator.passphraseEntropy(wordCount: Int(wordCount))
        case .pin:
            Double(Int(pinLength)) * log2(10)
        case .pattern:
            Double(pattern.filter { "aA9#x".contains($0) }.count) * log2(26)
        }
    }

    private func regenerate() {
        generated = (try? generate()) ?? ""
    }

    private func generate() throws -> String {
        switch mode {
        case .random:
            try PasswordGenerator.randomPassword(
                length: Int(length), classes: classes, excludeAmbiguous: excludeAmbiguous
            )
        case .passphrase:
            try PasswordGenerator.passphrase(
                wordCount: Int(wordCount), separator: separator,
                capitalize: capitalize, includeDigit: includeDigit
            )
        case .pin:
            try PasswordGenerator.pin(length: Int(pinLength))
        case .pattern:
            try PasswordGenerator.fromPattern(pattern, excludeAmbiguous: excludeAmbiguous)
        }
    }
}
