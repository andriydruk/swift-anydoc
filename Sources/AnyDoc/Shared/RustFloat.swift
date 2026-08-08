/// Rust `f64` decimal formatting, reproduced exactly.
///
/// Swift and Rust disagree twice over on how a `Double` prints: Rust's
/// `Display` never uses exponent notation and never appends a bare `.0`
/// (`1.0` -> `"1"`, `1e21` -> `"1000000000000000000000"`, `4e-7` ->
/// `"0.0000004"`), while Swift's interpolation does both. Spreadsheet output
/// is nothing but numbers, so this is the single largest byte-parity hazard
/// in the port (PLAN §2, gotcha 1) and every numeric run through the model
/// goes through here.

/// Rust `impl Display for f64`: the shortest decimal that round-trips,
/// written out in full positional notation.
func rustFormatF64(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-inf" : "inf" }

    var text = Substring("\(value)")
    var sign = ""
    if text.hasPrefix("-") {
        sign = "-"
        text = text.dropFirst()
    }
    // Swift may hand back exponent notation ("4e-07", "1e+21"); Rust never
    // does, so fold the exponent into the decimal point position instead.
    var exponent = 0
    if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        var expText = text[text.index(after: e)...]
        text = text[..<e]
        if expText.hasPrefix("+") { expText = expText.dropFirst() }
        exponent = Int(expText) ?? 0
    }
    var digits: [UInt8] = []
    var pointPos = 0
    var seenDot = false
    for byte in text.utf8 {
        if byte == UInt8(ascii: ".") {
            seenDot = true
            continue
        }
        digits.append(byte)
        if !seenDot { pointPos += 1 }
    }
    pointPos += exponent
    return sign + positionalDecimal(digits, pointPos)
}

/// Lay digits out around a decimal point at `pointPos` digits from the left,
/// padding with zeros on whichever side the point falls outside the digits.
private func positionalDecimal(_ digits: [UInt8], _ pointPos: Int) -> String {
    var intPart: [UInt8]
    var fracPart: [UInt8]
    if pointPos <= 0 {
        intPart = [UInt8(ascii: "0")]
        fracPart = [UInt8](repeating: UInt8(ascii: "0"), count: -pointPos) + digits
    } else if pointPos >= digits.count {
        intPart = digits + [UInt8](repeating: UInt8(ascii: "0"), count: pointPos - digits.count)
        fracPart = []
    } else {
        intPart = Array(digits[..<pointPos])
        fracPart = Array(digits[pointPos...])
    }
    // Swift's `12.0` and `0.0` carry a placeholder fraction Rust omits.
    while fracPart.last == UInt8(ascii: "0") { fracPart.removeLast() }
    while intPart.count > 1 && intPart.first == UInt8(ascii: "0") { intPart.removeFirst() }
    if fracPart.isEmpty {
        return String(decoding: intPart, as: UTF8.self)
    }
    return String(decoding: intPart, as: UTF8.self) + "." + String(decoding: fracPart, as: UTF8.self)
}

/// Round to `significantDigits` significant decimal digits the way Rust's
/// `format!("{f:.<n>e}")` does: against the *exact* binary value, ties to
/// even. Rounding the shortest representation instead would disagree
/// wherever the shortest form lands exactly on a tie that the exact value
/// does not.
func roundToSignificantDigits(_ value: Double, _ significantDigits: Int) -> Double {
    if !value.isFinite || value == 0 { return value }
    let negative = value < 0
    var (digits, scale) = exactDecimalDigits(abs(value))
    if digits.count > significantDigits {
        let dropped = digits.count - significantDigits
        var kept = Array(digits[..<significantDigits])
        let rest = digits[significantDigits...]
        scale += dropped
        let first = rest[rest.startIndex]
        let roundUp: Bool
        if first > UInt8(ascii: "5") {
            roundUp = true
        } else if first < UInt8(ascii: "5") {
            roundUp = false
        } else if rest.dropFirst().contains(where: { $0 != UInt8(ascii: "0") }) {
            roundUp = true
        } else {
            // Exact tie: round half to even.
            roundUp = (kept[kept.count - 1] - UInt8(ascii: "0")) % 2 == 1
        }
        if roundUp {
            var i = kept.count - 1
            while i >= 0 {
                if kept[i] == UInt8(ascii: "9") {
                    kept[i] = UInt8(ascii: "0")
                    i -= 1
                } else {
                    kept[i] += 1
                    break
                }
            }
            if i < 0 {
                // All nines carried out: 999... -> 1000..., one digit wider.
                kept.insert(UInt8(ascii: "1"), at: 0)
                kept.removeLast()
                scale += 1
            }
        }
        digits = kept
    }
    let text = String(decoding: digits, as: UTF8.self) + "e" + String(scale)
    // Swift's parser is correctly rounded, so this reproduces Rust's
    // `str::parse::<f64>()` on the same digits.
    guard let rounded = Double(text) else { return value }
    return negative ? -rounded : rounded
}

/// The exact decimal expansion of a finite, strictly positive `Double`:
/// `digits × 10^scale`, with no leading zero. Every binary float has one, and
/// it is what Rust's fixed-precision formatter rounds against.
private func exactDecimalDigits(_ value: Double) -> (digits: [UInt8], scale: Int) {
    let bits = value.bitPattern
    let rawExponent = Int((bits >> 52) & 0x7FF)
    let fraction = bits & 0x000F_FFFF_FFFF_FFFF
    let mantissa: UInt64
    let exponent: Int
    if rawExponent == 0 {
        mantissa = fraction
        exponent = -1074
    } else {
        mantissa = fraction | (1 << 52)
        exponent = rawExponent - 1075
    }
    if mantissa == 0 { return ([UInt8(ascii: "0")], 0) }

    var limbs = bigFromUInt64(mantissa)
    var scale = 0
    if exponent >= 0 {
        // value = mantissa × 2^exponent, an exact integer.
        for _ in 0..<exponent { bigMultiply(&limbs, by: 2) }
    } else {
        // value = mantissa / 2^k = (mantissa × 5^k) / 10^k.
        let k = -exponent
        for _ in 0..<k { bigMultiply(&limbs, by: 5) }
        scale = -k
    }
    return (bigDecimalDigits(limbs), scale)
}

// A minimal unsigned big integer, little-endian base 1e9. Only the two
// operations the exact expansion needs are implemented.

private let bigBase: UInt64 = 1_000_000_000

private func bigFromUInt64(_ value: UInt64) -> [UInt32] {
    var limbs: [UInt32] = []
    var rest = value
    while rest > 0 {
        limbs.append(UInt32(rest % bigBase))
        rest /= bigBase
    }
    return limbs.isEmpty ? [0] : limbs
}

private func bigMultiply(_ limbs: inout [UInt32], by factor: UInt32) {
    var carry: UInt64 = 0
    for i in limbs.indices {
        let product = UInt64(limbs[i]) * UInt64(factor) + carry
        limbs[i] = UInt32(product % bigBase)
        carry = product / bigBase
    }
    while carry > 0 {
        limbs.append(UInt32(carry % bigBase))
        carry /= bigBase
    }
}

private func bigDecimalDigits(_ limbs: [UInt32]) -> [UInt8] {
    var out: [UInt8] = []
    for (offset, limb) in limbs.reversed().enumerated() {
        let text = String(limb)
        if offset > 0 {
            // Interior limbs carry their full nine digits, leading zeros included.
            out.append(contentsOf: [UInt8](repeating: UInt8(ascii: "0"), count: 9 - text.utf8.count))
        }
        out.append(contentsOf: Array(text.utf8))
    }
    return out
}

/// Rust's saturating `f64 as u64` cast: NaN and anything at or below zero
/// become 0, anything at or above `u64::MAX` becomes `u64::MAX`.
func rustSaturatingUInt64(_ value: Double) -> UInt64 {
    if value.isNaN || value <= 0 { return 0 }
    if value >= 18_446_744_073_709_551_616.0 { return .max }
    return UInt64(value)
}
