import Foundation

/// Conservative password-entropy estimate: character-class pool size raised to
/// length, minus penalties for repetition. Always presented to users as an
/// *estimate* (§10.4) — never as a guarantee.
public enum PasswordStrength {

    public static func estimateEntropyBits(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var pool = 0
        if password.contains(where: { $0.isLowercase }) { pool += 26 }
        if password.contains(where: { $0.isUppercase }) { pool += 26 }
        if password.contains(where: { $0.isNumber }) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        if pool == 0 { pool = 26 }

        // Unique-character ratio dampens "aaaaaaaa"-style inputs.
        let uniqueRatio = Double(Set(password).count) / Double(password.count)
        let effectiveLength = Double(password.count) * (0.6 + 0.4 * uniqueRatio)
        return effectiveLength * log2(Double(pool))
    }
}
