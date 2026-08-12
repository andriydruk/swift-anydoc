/// Text-quality detection, ported from `text_quality.rs` in pdf-inspector.
///
/// Extraction can produce plausible-looking bytes that are actually garbage:
/// failed CID→Unicode mappings, broken ToUnicode CMaps, mojibake. This wave
/// ports the markdown-level detectors and the statistical discriminator they
/// rest on.
///
/// The hard case is a ToUnicode CMap that shifts every character by a
/// per-range constant, so `Certificate` extracts as `8VceZWZTReV`. That output
/// is 100% printable ASCII with word-like token lengths — it produces no
/// replacement characters and defeats every symbol-soup test — so it needs a
/// discriminator of its own.

/// English letter frequencies as percentages, a–z.
///
/// Used as a natural-language reference rather than an English test: every
/// Latin-script language in the reference's corpus — Swedish, Finnish,
/// Turkish, German, romaji — scores at least 0.80 cosine against it, while
/// substitution-cipher text scores about 0.53.
private let pdfEnglishLetterFrequency: [Double] = [
    8.2, 1.5, 2.8, 4.3, 12.7, 2.2, 2.0, 6.1, 7.0, 0.15, 0.8, 4.0, 2.4, 6.7, 7.5, 1.9, 0.1, 6.0,
    6.3, 9.1, 2.8, 1.0, 2.4, 0.15, 2.0, 0.07,
]

/// Letter statistics for detecting substitution-cipher garbling.
struct PdfCipherGarbleStats {
    /// Case-folded ASCII letter histogram.
    private(set) var letterCounts = [UInt32](repeating: 0, count: 26)
    private(set) var asciiLetters = 0
    private(set) var asciiVowels = 0
    /// Accented Latin letters. These count toward Latin dominance only.
    private(set) var latinExtendedLetters = 0
    private(set) var nonLatinLetters = 0
    /// Adjacent ASCII-letter pairs, and how many switch from lowercase
    /// straight to uppercase mid-word.
    private(set) var letterBigrams = 0
    private(set) var caseShiftBigrams = 0

    init() {}

    /// Accumulate one string's statistics.
    ///
    /// Note the bigram chain resets at every non-ASCII-letter character, so
    /// "pairs" means pairs *inside* a run of ASCII letters — a word boundary
    /// is not a bigram.
    mutating func add(_ text: String) {
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if pdfIsAsciiAlphabetic(scalar) {
                let lowered = pdfAsciiLowercased(scalar)
                letterCounts[Int(lowered.value - 0x61)] += 1
                asciiLetters += 1
                if lowered == "a" || lowered == "e" || lowered == "i" || lowered == "o"
                    || lowered == "u"
                {
                    asciiVowels += 1
                }
                if let previous {
                    letterBigrams += 1
                    if previous.value >= 0x61 && previous.value <= 0x7A && scalar.value >= 0x41
                        && scalar.value <= 0x5A
                    {
                        caseShiftBigrams += 1
                    }
                }
                previous = scalar
            } else {
                if scalar.properties.isAlphabetic {
                    // Latin-1 Supplement through Latin Extended-B, plus Latin
                    // Extended Additional.
                    if (0xC0...0x24F).contains(scalar.value)
                        || (0x1E00...0x1EFF).contains(scalar.value)
                    {
                        latinExtendedLetters += 1
                    } else {
                        nonLatinLetters += 1
                    }
                }
                previous = nil
            }
        }
    }

    /// Cosine similarity between the observed histogram and English
    /// frequencies.
    ///
    /// A shifted alphabet permutes the histogram, which destroys this
    /// similarity whatever the shift amount. Empty input scores a perfect 1,
    /// so nothing is condemned for having no letters.
    func englishCosine() -> Double {
        if asciiLetters == 0 { return 1.0 }
        let n = Double(asciiLetters)
        var dot = 0.0
        var observedNorm = 0.0
        for (count, frequency) in zip(letterCounts, pdfEnglishLetterFrequency) {
            let p = Double(count) / n
            dot += p * frequency
            observedNorm += p * p
        }
        let englishNorm = pdfEnglishLetterFrequency.map { $0 * $0 }.reduce(0, +).squareRoot()
        return dot / (observedNorm.squareRoot() * englishNorm)
    }

    /// The same cosine with *both* histograms sorted descending — comparing
    /// the frequency profile's shape while ignoring which letter sits where.
    ///
    /// A substitution cipher is a bijection, so it preserves this shape
    /// exactly whatever the offset. Non-linguistic ASCII does not: a small
    /// alphabet gives a far steeper profile.
    func englishShapeCosine() -> Double {
        if asciiLetters == 0 { return 1.0 }
        let n = Double(asciiLetters)
        let observed = letterCounts.map { Double($0) / n }.sorted(by: >)
        let english = pdfEnglishLetterFrequency.sorted(by: >)
        let dot = zip(observed, english).map(*).reduce(0, +)
        let observedNorm = observed.map { $0 * $0 }.reduce(0, +).squareRoot()
        let englishNorm = english.map { $0 * $0 }.reduce(0, +).squareRoot()
        return dot / (observedNorm * englishNorm)
    }

    /// Whether the statistics look like a shifted alphabet rather than text.
    ///
    /// The thresholds come from the reference's corpus and are tight on
    /// purpose: the closest legitimate document sits at a vowel ratio of
    /// 0.264 against a 0.30 bar, and at a cosine of 0.801 against 0.60.
    func looksGarbled() -> Bool {
        // A statistically meaningful, Latin-dominant sample first.
        if asciiLetters < 200 || nonLatinLetters > asciiLetters + latinExtendedLetters {
            return false
        }

        // Real Latin-script text keeps vowels above about 30% of letters even
        // when thick with acronyms and part numbers; a shifted alphabet
        // starves them.
        let vowelRatio = Double(asciiVowels) / Double(asciiLetters)
        if vowelRatio > 0.30 { return false }

        // Signal one: lowercase→uppercase transitions inside words. A shifted
        // lowercase alphabet straddles the ASCII uppercase block, so garbled
        // words flip case constantly. Real documents stay at or under 0.02
        // even when full of camelCase identifiers.
        let caseShifts =
            letterBigrams >= 100 && Double(caseShiftBigrams) >= Double(letterBigrams) * 0.10

        // Signal two: the histogram is a *permutation* of natural language —
        // an English-like frequency shape but with the letters in the wrong
        // positions. Case-independent, so it catches all-lowercase and
        // all-uppercase shifts too. Genuinely non-linguistic ASCII fails one
        // half or the other: DNA and hex dumps have too steep a profile, while
        // protein sequences, ticker symbols and base64 are not unlike English
        // enough in position.
        let permutedLanguage = englishCosine() < 0.60 && englishShapeCosine() >= 0.90

        return caseShifts || permutedLanguage
    }
}

/// Whether `$` is being used as a word separator, which a broken ToUnicode
/// CMap produces as `Word$Word$Word`.
///
/// Two ways to trigger, because financial text legitimately contains dollar
/// signs: more than half of them sitting between letters, or more than twenty
/// such occurrences outright — far beyond what a price list produces.
func pdfHasDollarAsSpacePattern(_ markdown: String) -> Bool {
    let bytes = Array(markdown.utf8)
    let totalDollars = bytes.filter { $0 == UInt8(ascii: "$") }.count
    guard totalDollars > 10, bytes.count >= 2 else { return false }

    var letterDollarLetter = 0
    for index in 1..<(bytes.count - 1)
    where bytes[index] == UInt8(ascii: "$") && pdfIsAsciiAlphabeticByte(bytes[index - 1])
        && pdfIsAsciiAlphabeticByte(bytes[index + 1]) {
        letterDollarLetter += 1
    }
    return letterDollarLetter > 20 || letterDollarLetter * 2 > totalDollars
}

/// Whether a page's markdown shows a broken font encoding.
///
/// Three heuristics in increasing subtlety: any replacement character at all,
/// the dollar-as-space pattern, and finally the letter statistics — which are
/// the only thing that catches a shift cipher, since its output is clean
/// printable ASCII.
func pdfDetectEncodingIssues(_ markdown: String) -> Bool {
    if markdown.unicodeScalars.contains(where: { $0.value == 0xFFFD }) { return true }
    if pdfHasDollarAsSpacePattern(markdown) { return true }
    var stats = PdfCipherGarbleStats()
    stats.add(markdown)
    return stats.looksGarbled()
}

// MARK: - byte and scalar helpers

func pdfIsAsciiAlphabeticByte(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
}

func pdfIsAsciiAlphabetic(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value >= 0x41 && scalar.value <= 0x5A)
        || (scalar.value >= 0x61 && scalar.value <= 0x7A)
}

func pdfAsciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    if scalar.value >= 0x41 && scalar.value <= 0x5A {
        return Unicode.Scalar(scalar.value + 32)!
    }
    return scalar
}
