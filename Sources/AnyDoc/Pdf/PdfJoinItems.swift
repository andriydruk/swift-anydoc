/// Whether two adjacent text items belong to the same word, ported from
/// `should_join_items` in pdf-inspector's `text_utils.rs`.
///
/// A PDF never says where words end. It says where glyphs are, and the reader
/// has to decide whether the space between two of them is a *space* or merely
/// the gap between letters. Everything here is that one decision, and it is
/// long because the answer depends on what kind of thing is on each side:
/// punctuation, digits, a CID font emitting one word per operator, a
/// letter-spaced page, or ordinary prose.
///
/// The order of the tests is the design. Cheap textual signals come first and
/// override geometry entirely — a leading `.` joins whatever the gap says,
/// because `www` and `.com` are one word however they were positioned.
/// **Not yet called.** This port's line assembler, `pdfNeedsSpace`,
/// reimplements the geometry inline instead; see the note there. The two
/// agree everywhere `PdfJoinDuplicationTests` checks except on an
/// unmeasured width.
func pdfShouldJoinItems(
    previous: PdfLayoutItem, current: PdfLayoutItem, singleCharacterThreshold: Float
) -> Bool {
    // An explicit space in the text is the author's own answer.
    if previous.text.hasSuffix(" ") || current.text.hasPrefix(" ") { return false }

    let previousLast = previous.text.rustTrimEnd().unicodeScalars.last
    let currentFirst = current.text.rustTrimStart().unicodeScalars.first

    // Punctuation that never takes a leading space.
    if let currentFirst {
        switch currentFirst {
        case ".", ",", ";", "!", "?", ")", "]", "}", "'":
            return true
        default:
            break
        }
    }

    // A colon before a value takes one: `Clave:` + `T9N2I6`.
    if let previousLast, let currentFirst, previousLast == ":",
        pdfIsAlphanumericScalar(currentFirst)
    {
        return false
    }

    if previous.width > 0 {
        // Measured in whichever direction the pair runs, so a right-to-left
        // line is judged the same way.
        let gap =
            previous.x <= current.x
            ? current.x - (previous.x + previous.width)
            : previous.x - (current.x + current.width)
        let fontSize = previous.fontSize

        // A column-scale gap is not a word boundary, and a large negative one
        // means `Tc`/`Tw` inflated the widths past where the next item starts.
        if gap > fontSize * 3 || gap < -fontSize { return false }

        let previousCharacters = previous.text.rustTrim().unicodeScalars.count
        let currentCharacters = current.text.rustTrim().unicodeScalars.count
        let previousTrimmedLast = previous.text.rustTrim().unicodeScalars.last
        let currentTrimmedFirst = current.text.rustTrim().unicodeScalars.first
        let isCjk =
            (previousTrimmedLast.map(pdfIsCjkScalarValue) ?? false)
            || (currentTrimmedFirst.map(pdfIsCjkScalarValue) ?? false)

        // A CID font emits one word per text operator, with the gap between
        // words at essentially zero — so a zero gap there means a *space*,
        // the opposite of what it means elsewhere. Not for CJK, which is set
        // without spaces at all.
        if !isCjk && gap >= 0 && gap < fontSize * 0.01 && pdfIsCidFontName(previous.fontName) {
            let previousWordCount = previous.text.rustSplitWhitespace().count
            // Three words means the operator carried a whole phrase, so this
            // is a mid-word boundary rather than a word one.
            if previousWordCount >= 3 { return gap < fontSize * 0.15 }
            return false
        }

        // Digits, commas, periods and percent signs close together are one
        // number. Spaces inside numbers are rare enough that the threshold
        // can be generous.
        if let previousLast, let currentFirst {
            let previousIsNumeric =
                pdfIsAsciiDigitScalarValue(previousLast) || previousLast == ","
                || previousLast == "."
            let currentIsNumeric =
                pdfIsAsciiDigitScalarValue(currentFirst) || currentFirst == "%"
                || currentFirst == "."
            if previousIsNumeric && currentIsNumeric {
                return gap > -fontSize && gap < fontSize * 0.3
            }
            if (previousLast == "+" || previousLast == "-")
                && pdfIsAsciiDigitScalarValue(currentFirst)
            {
                return gap > -fontSize && gap < fontSize * 0.3
            }
        }

        // On a letter-spaced page every gap is wide, so the comparison has to
        // be against *character width* rather than font size.
        if singleCharacterThreshold > 0.20 {
            if previousCharacters == 1 {
                // One character's rendered width is an exact reference.
                return gap < previous.width * 1.25
            }
            if currentCharacters == 1 {
                // Averaging over the previous item normalises for a mix of
                // wide and narrow glyphs.
                return gap < (previous.width / Float(previousCharacters)) * 1.25
            }
            return gap < fontSize * singleCharacterThreshold
        }

        // A single-character fragment against a multi-character item: a split
        // word like `b` + `illion`, so be moderately generous.
        if (previousCharacters == 1) != (currentCharacters == 1) {
            return gap < fontSize * 0.20
        }

        // Both single: per-glyph positioning. Numbers get a looser bar than
        // letters, because a word boundary between digits is rarer.
        if previousCharacters == 1 && currentCharacters == 1 {
            if let previousLast, let currentFirst {
                let previousNumeric =
                    pdfIsAsciiDigitScalarValue(previousLast) || previousLast == ","
                    || previousLast == "." || previousLast == "%" || previousLast == "+"
                    || previousLast == "-"
                let currentNumeric =
                    pdfIsAsciiDigitScalarValue(currentFirst) || currentFirst == ","
                    || currentFirst == "." || currentFirst == "%"
                if previousNumeric && currentNumeric { return gap < fontSize * 0.25 }
            }
            return gap < fontSize * singleCharacterThreshold
        }

        // Two multi-character items meeting lowercase-to-lowercase get a
        // slightly wider bar: imprecise CID metrics otherwise split
        // `enterta` + `inment`. A capital on either side keeps the tight one,
        // since `LCOE` + `WITH` really is a boundary.
        if previousCharacters >= 2 && currentCharacters >= 2 {
            let previousEndsLower = previousTrimmedLast?.properties.isLowercase ?? false
            let currentStartsLower = currentTrimmedFirst?.properties.isLowercase ?? false
            if previousEndsLower && currentStartsLower { return gap < fontSize * 0.18 }
        }
        return gap < fontSize * 0.15
    }

    // No measured width: estimate one and fall back to case heuristics.
    let characterWidth = previous.fontSize * 0.45
    let estimatedWidth = Float(previous.text.unicodeScalars.count) * characterWidth
    let gap = current.x - (previous.x + estimatedWidth)

    if gap > characterWidth * 6 { return false }

    // CJK is set without spaces, so the case rules below would inject them
    // into the middle of words.
    let isCjk =
        (previousLast.map(pdfIsCjkScalarValue) ?? false)
        || (currentFirst.map(pdfIsCjkScalarValue) ?? false)
    if isCjk { return gap < characterWidth * 0.8 }

    guard let previousLast, let currentFirst,
        previousLast.properties.isAlphabetic, currentFirst.properties.isAlphabetic
    else {
        return gap < characterWidth * 0.5
    }

    let sameCase =
        (previousLast.properties.isUppercase && currentFirst.properties.isUppercase)
        || (previousLast.properties.isLowercase && currentFirst.properties.isLowercase)
    if sameCase {
        // Likely two fragments of one word: `CONST` + `ANCIA`.
        return gap < characterWidth * 0.8
    }
    if previousLast.properties.isLowercase && currentFirst.properties.isUppercase {
        // Words do not go from lowercase to uppercase mid-word, so this is a
        // boundary whatever the distance.
        return false
    }
    // Uppercase to lowercase — `REGISTRO` + `para` — is usually a boundary
    // too, but not always, so it keeps a threshold rather than a verdict.
    return gap < characterWidth * 0.3
}

/// Whether a scalar is an ASCII digit.
func pdfIsAsciiDigitScalarValue(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 0x30 && scalar.value <= 0x39
}
