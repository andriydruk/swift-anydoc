/// Unicode NFKC normalisation.
///
/// Ported not from a function but from a dependency: the reference calls
/// `unicode-normalization`'s `nfkc()` inside `expand_ligatures`, so this
/// reimplements the algorithm and takes its tables from that same crate — see
/// `scripts/gen-nfkc-tables.sh`.
///
/// It exists for one caller. `expand_ligatures` normalises only when Arabic
/// presentation forms are present, which is how a PDF stores pre-shaped Arabic
/// glyphs; NFKC turns those back into base letters so the text is searchable.
/// The rest of Unicode comes along because the operation is defined over
/// whole strings, not over the range that motivated it.
///
/// Three stages, as the standard defines them: compatibility decomposition,
/// canonical ordering of combining marks, then canonical composition.

// MARK: - Hangul

/// Hangul is arithmetic rather than tabular, so it is computed instead of
/// stored — 11,172 syllables that would otherwise dominate the tables.
private let pdfHangulSBase: UInt32 = 0xAC00
private let pdfHangulLBase: UInt32 = 0x1100
private let pdfHangulVBase: UInt32 = 0x1161
private let pdfHangulTBase: UInt32 = 0x11A7
private let pdfHangulLCount: UInt32 = 19
private let pdfHangulVCount: UInt32 = 21
private let pdfHangulTCount: UInt32 = 28
private let pdfHangulNCount: UInt32 = 588  // V × T
private let pdfHangulSCount: UInt32 = 11172  // L × N

/// A syllable's jamo, or `nil` if it is not one.
private func pdfHangulDecompose(_ scalar: UInt32) -> [UInt32]? {
    guard scalar >= pdfHangulSBase, scalar < pdfHangulSBase + pdfHangulSCount else {
        return nil
    }
    let index = scalar - pdfHangulSBase
    let lead = pdfHangulLBase + index / pdfHangulNCount
    let vowel = pdfHangulVBase + (index % pdfHangulNCount) / pdfHangulTCount
    let trail = index % pdfHangulTCount
    // A syllable with no trailing consonant is two jamo, not three.
    return trail == 0 ? [lead, vowel] : [lead, vowel, pdfHangulTBase + trail]
}

/// The syllable two jamo compose to, or `nil`.
private func pdfHangulCompose(_ first: UInt32, _ second: UInt32) -> UInt32? {
    // Lead + vowel makes a syllable without a trailing consonant.
    if first >= pdfHangulLBase, first < pdfHangulLBase + pdfHangulLCount,
        second >= pdfHangulVBase, second < pdfHangulVBase + pdfHangulVCount
    {
        let lead = first - pdfHangulLBase
        let vowel = second - pdfHangulVBase
        return pdfHangulSBase + (lead * pdfHangulVCount + vowel) * pdfHangulTCount
    }
    // Syllable + trailing consonant, but only onto a syllable that has none.
    if first >= pdfHangulSBase, first < pdfHangulSBase + pdfHangulSCount,
        (first - pdfHangulSBase) % pdfHangulTCount == 0,
        second > pdfHangulTBase, second < pdfHangulTBase + pdfHangulTCount
    {
        return first + (second - pdfHangulTBase)
    }
    return nil
}

// MARK: - table lookups

/// The canonical combining class of a scalar; zero for a starter.
func pdfCombiningClass(_ scalar: UInt32) -> UInt32 {
    var low = 0
    var high = pdfCombiningKeys.count - 1
    while low <= high {
        let middle = (low + high) / 2
        let key = pdfCombiningKeys[middle]
        if key == scalar { return pdfCombiningValues[middle] }
        if key < scalar { low = middle + 1 } else { high = middle - 1 }
    }
    return 0
}

/// A scalar's full compatibility decomposition, or `nil` when it is its own.
private func pdfCompatibilityDecomposition(_ scalar: UInt32) -> ArraySlice<UInt32>? {
    if let hangul = pdfHangulDecompose(scalar) { return hangul[...] }
    var low = 0
    var high = pdfNfkdKeys.count - 1
    while low <= high {
        let middle = (low + high) / 2
        let key = pdfNfkdKeys[middle]
        if key == scalar {
            return pdfNfkdValues[Int(pdfNfkdOffsets[middle])..<Int(pdfNfkdOffsets[middle + 1])]
        }
        if key < scalar { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
}

/// The scalar a starter and a following mark compose to, if any.
private func pdfComposePair(_ starter: UInt32, _ second: UInt32) -> UInt32? {
    if let hangul = pdfHangulCompose(starter, second) { return hangul }
    // Packed into one value so the search compares once rather than twice.
    let key = UInt64(starter) << 21 | UInt64(second)
    var low = 0
    var high = pdfComposeKeys.count - 1
    while low <= high {
        let middle = (low + high) / 2
        let candidate = pdfComposeKeys[middle]
        if candidate == key { return pdfComposeValues[middle] }
        if candidate < key { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
}

// MARK: - the algorithm

/// The string in Normalisation Form KC.
func pdfNfkc(_ text: String) -> String {
    // Stage one: decompose. The tables hold *full* expansions, so no recursion
    // is needed here.
    var scalars: [UInt32] = []
    for scalar in text.unicodeScalars {
        if let decomposition = pdfCompatibilityDecomposition(scalar.value) {
            scalars.append(contentsOf: decomposition)
        } else {
            scalars.append(scalar.value)
        }
    }

    // Stage two: canonical ordering. Combining marks sort by class within each
    // run, and the sort must be *stable* — marks of equal class keep their
    // order, which is what makes normalisation idempotent. A bubble sort over
    // the run is what the standard describes and is stable by construction.
    var index = 0
    while index < scalars.count {
        guard pdfCombiningClass(scalars[index]) != 0 else {
            index += 1
            continue
        }
        var end = index
        while end < scalars.count && pdfCombiningClass(scalars[end]) != 0 { end += 1 }
        if end - index > 1 {
            var swapped = true
            while swapped {
                swapped = false
                for position in (index + 1)..<end
                where pdfCombiningClass(scalars[position - 1])
                    > pdfCombiningClass(scalars[position])
                {
                    scalars.swapAt(position - 1, position)
                    swapped = true
                }
            }
        }
        index = end
    }

    // Stage three: compose. A mark can only join the last *starter*, and only
    // if nothing blocks it — a preceding mark of equal or higher class stands
    // between them and prevents the join.
    var result: [UInt32] = []
    var starterIndex: Int?
    var lastClass: UInt32 = 0
    for scalar in scalars {
        let scalarClass = pdfCombiningClass(scalar)
        if let index = starterIndex,
            lastClass == 0 || lastClass < scalarClass,
            let composed = pdfComposePair(result[index], scalar)
        {
            result[index] = composed
            // `lastClass` deliberately does not move: the composed character
            // absorbed the mark, so the next one is judged against whatever
            // came before it.
            continue
        }
        if scalarClass == 0 {
            starterIndex = result.count
            lastClass = 0
        } else {
            lastClass = scalarClass
        }
        result.append(scalar)
    }

    var view = String.UnicodeScalarView()
    for value in result {
        if let scalar = Unicode.Scalar(value) { view.append(scalar) }
    }
    return String(view)
}
