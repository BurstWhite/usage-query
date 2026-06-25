import Foundation

public struct TokenEstimator: Sendable {
    public init() {}

    public func estimateTextTokens(_ text: String, provider: UsageProviderKind) -> Int {
        let scalars = text.unicodeScalars
        if scalars.isEmpty {
            return 0
        }

        var cjkScalars = 0
        var nonCJKScalars = 0
        for scalar in scalars {
            if scalar.properties.isWhitespace {
                continue
            }
            if isCJK(scalar) {
                cjkScalars += 1
            } else {
                nonCJKScalars += 1
            }
        }

        let providerMultiplier: Double = provider == .claude ? 1.05 : 1.0
        let roughTokens = (Double(cjkScalars) * 1.1 + Double(nonCJKScalars) / 4.0) * providerMultiplier
        return max(1, Int(roughTokens.rounded(.up)))
    }

    private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,
             0x3400...0x4DBF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
