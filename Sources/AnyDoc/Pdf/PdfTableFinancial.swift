/// Splitting a consolidated financial row back into its columns, ported from
/// pdf-inspector's `tables/financial.rs` and `expand_consolidated_items`.
///
/// A financial statement often emits a whole row of figures as **one** text
/// item — `$ 5,147,649  114,167  —  778,177` — because the producer drew it
/// with one `Tj`. No amount of column clustering can recover the grid from
/// that: there is only one x position. So the item is split before detection
/// runs, on the assumption that a very wide item holding nothing but numbers
/// is a row of them, spaced evenly across its own width.
///
/// The guess is deliberately narrow. A single letter pair anywhere in the
/// text disqualifies it, and so does any token that is not a figure, a dash
/// or a dollar sign.

/// Whether a token is a figure, allowing the punctuation financial tables
/// use — including the parentheses that mark a negative.
func pdfIsNumericToken<S: StringProtocol>(_ token: S) -> Bool {
    var sawDigit = false
    for scalar in token.unicodeScalars {
        if scalar >= "0", scalar <= "9" {
            sawDigit = true
        } else if !",.()-+%".unicodeScalars.contains(scalar) {
            return false
        }
    }
    return sawDigit
}

/// Whether a token is one of the dashes used to mark a nil entry.
func pdfIsDashToken<S: StringProtocol>(_ token: S) -> Bool {
    ["\u{2014}", "\u{2013}", "-", "\u{2012}"].contains(String(token))
}

/// Whether the text holds two consecutive letters, which is enough to say it
/// carries a word and is therefore not a pure row of figures.
func pdfHasAlphabeticWords(_ text: String) -> Bool {
    var consecutive = 0
    for scalar in text.unicodeScalars {
        if scalar.properties.isAlphabetic {
            consecutive += 1
            if consecutive >= 2 { return true }
        } else {
            consecutive = 0
        }
    }
    return false
}

/// The individual values in a consolidated row, or nothing if any token is
/// not one.
///
/// A `$` binds to the figure after it, so `$ 5,147,649` is one value rather
/// than two.
func pdfTokenizeFinancialValues(_ text: String) -> [String]? {
    let tokens = text.rustSplitWhitespace().map(String.init)
    guard !tokens.isEmpty else { return nil }

    var values: [String] = []
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if token == "$" {
            guard index + 1 < tokens.count, pdfIsNumericToken(tokens[index + 1]) else {
                return nil
            }
            values.append(token + " " + tokens[index + 1])
            index += 2
        } else if pdfIsNumericToken(token) || pdfIsDashToken(token) {
            values.append(token)
            index += 1
        } else {
            // Anything else means this is not a pure row of values.
            return nil
        }
    }
    return values.isEmpty ? nil : values
}

/// Split one item into its values, if it is a consolidated financial row.
///
/// The sub-items are placed at the centres of equal slices of the original's
/// width. That is a fiction — the real figures are right-aligned in their
/// columns — but it is a *consistent* fiction across the rows of one table,
/// which is all the column clustering needs.
func pdfTrySplitFinancialItem(_ item: PdfLayoutItem) -> [PdfLayoutItem]? {
    // Twenty ems is far wider than any single figure.
    guard item.width > item.fontSize * 20 else { return nil }
    guard !pdfHasAlphabeticWords(item.text) else { return nil }
    guard let values = pdfTokenizeFinancialValues(item.text), values.count >= 3 else {
        return nil
    }

    let spacing = item.width / Float(values.count)
    return values.enumerated().map { index, value in
        var sub = item
        sub.text = value
        sub.x = item.x + spacing * Float(index) + spacing * 0.5
        sub.width = spacing * 0.9
        return sub
    }
}

/// Expand every consolidated row, keeping a map back to the original items.
func pdfExpandConsolidatedItems(
    _ items: [PdfLayoutItem]
) -> (expanded: [PdfLayoutItem], indexMap: [Int]) {
    var expanded: [PdfLayoutItem] = []
    var indexMap: [Int] = []
    for (index, item) in items.enumerated() {
        if let parts = pdfTrySplitFinancialItem(item) {
            for part in parts {
                expanded.append(part)
                indexMap.append(index)
            }
        } else {
            expanded.append(item)
            indexMap.append(index)
        }
    }
    return (expanded, indexMap)
}
