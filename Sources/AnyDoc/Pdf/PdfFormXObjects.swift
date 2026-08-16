/// Form XObjects, ported from `extractor/xobjects.rs`.
///
/// A `Do` operator invokes an XObject: an image, or a *form* — a content
/// stream of its own, with its own resources, drawn under the graphics state
/// in effect. Real documents put a great deal of text in forms: letterheads,
/// repeated furniture, anything a producer factored out. A reader that
/// ignores `Do` loses all of it silently.
///
/// **This port inlines rather than recurses, which is a deliberate
/// structural divergence.** The reference has a second five-hundred-line
/// content-stream walker specialised for forms. The PDF specification says a
/// form invocation means `q`, the form's `/Matrix` as a `cm`, the form's
/// content, then `Q` — so splicing exactly that into the operation stream
/// lets the one walker this port already has handle both, with the same
/// result and none of the duplication.
///
/// Two things that inlining would get wrong are handled explicitly: a form's
/// fonts are its own, so its `Tf` names are rewritten to a namespaced key
/// before splicing and the caller's font map is extended to match; and
/// nesting is capped, since a form may invoke another.

/// How deep form invocation is followed. The reference's limit.
let pdfMaxFormXObjectDepth = 5

/// A page's operations with every form XObject invocation spliced in.
///
/// - Parameter fontKey: called for each font resource found inside a form,
///   with the namespaced name it was given and the font dictionary, so the
///   caller can extend its own per-name font tables.
func pdfInlineFormXObjects(
    _ operations: [PdfOperation],
    _ document: inout PdfDocument,
    resources: PdfDictionary?,
    depth: Int = 0,
    namespace: String = "",
    fontKey: (String, PdfDictionary) -> Void
) -> [PdfOperation] {
    guard depth < pdfMaxFormXObjectDepth, let resources else { return operations }

    // The names a `Do` can invoke, and the streams behind them. Only forms:
    // an image XObject draws no text and is handled elsewhere.
    var forms: [String: PdfObjectId] = [:]
    if let xobjects = document.value(resources, "XObject")?.asDictionary {
        for key in xobjects.keys {
            let name = String(decoding: key, as: UTF8.self)
            guard let reference = xobjects[key]?.asReference,
                let stream = document.object(reference).asStream,
                stream.dict["Subtype"]?.asName == Array("Form".utf8)
            else { continue }
            forms[name] = reference
        }
    }
    if forms.isEmpty { return operations }

    var out: [PdfOperation] = []
    for operation in operations {
        guard operation.operator == "Do", let operand = operation.operands.first,
            let nameBytes = operand.asName
        else {
            out.append(operation)
            continue
        }
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard let id = forms[name], let stream = document.object(id).asStream,
            let data = document.decodedStream(stream)
        else {
            out.append(operation)
            continue
        }

        // The form's own resources name its fonts. They are given a
        // namespaced key so a `/F1` inside a form cannot be mistaken for the
        // page's `/F1`, which would silently pick the wrong glyph widths.
        let formResources = document.value(stream.dict, "Resources")?.asDictionary
        let innerNamespace = namespace + "\u{1}" + name
        // **Every** `Tf` inside the form is namespaced, including names the
        // form does not declare.
        //
        // The specification says resources are inherited, so a form with no
        // `/Resources` of its own should draw with the page's fonts. The
        // reference's `get_form_fonts` returns nothing at all in that case
        // and never consults the page, leaving those runs with no metrics
        // and a zero advance. Namespacing unconditionally reproduces that:
        // the name resolves to nothing here too. Inheriting instead — which
        // this port did until the item probe caught it — gives the run a
        // real width the reference never assigns.
        if let formResources, let fonts = document.value(formResources, "Font")?.asDictionary {
            for key in fonts.keys {
                let fontName = String(decoding: key, as: UTF8.self)
                guard let font = document.value(fonts, fontName)?.asDictionary else { continue }
                fontKey(innerNamespace + "\u{1}" + fontName, font)
            }
        }

        var inner = pdfParseContentStream(data)
        inner = pdfRenameFontOperands(inner, namespace: innerNamespace)
        // Recurse first, so a form nested inside this one is spliced with
        // its own namespace before this one's operations are wrapped.
        inner = pdfInlineFormXObjects(
            inner, &document, resources: formResources, depth: depth + 1,
            namespace: innerNamespace, fontKey: fontKey)

        // `q` … `Q` around the form's own `/Matrix`, which is what the
        // specification says the invocation means.
        out.append(PdfOperation(operator: "q", operands: []))
        if let matrix = pdfFormMatrix(&document, stream.dict) {
            out.append(
                PdfOperation(operator: "cm", operands: matrix.map { PdfObject.real($0) }))
        }
        out.append(contentsOf: inner)
        out.append(PdfOperation(operator: "Q", operands: []))
    }
    return out
}

/// A form's `/Matrix`, or nothing when it is absent or malformed.
///
/// A short or non-numeric array yields the identity in the reference, which
/// is the same as not emitting a `cm` at all.
func pdfFormMatrix(_ document: inout PdfDocument, _ dictionary: PdfDictionary) -> [Float]? {
    guard let array = document.value(dictionary, "Matrix")?.asArray, array.count >= 6
    else { return nil }
    var matrix: [Float] = []
    for (index, entry) in array.prefix(6).enumerated() {
        // The reference defaults a missing number to 1 on the diagonal and 0
        // elsewhere, which is the identity's shape.
        let number = document.resolve(entry).asNumber.map(Float.init)
        matrix.append(number ?? ((index == 0 || index == 3) ? 1 : 0))
    }
    return matrix == [1, 0, 0, 1, 0, 0] ? nil : matrix
}

/// Rewrite a form's `Tf` font names so its resources cannot collide with the
/// page's — and so a name the form does not declare resolves to nothing, as
/// it does in the reference.
func pdfRenameFontOperands(_ operations: [PdfOperation], namespace: String) -> [PdfOperation] {
    operations.map { operation in
        guard operation.operator == "Tf", let first = operation.operands.first,
            let name = first.asName
        else { return operation }
        var renamed = operation
        let qualified = namespace + "\u{1}" + String(decoding: name, as: UTF8.self)
        renamed.operands[0] = .name(Array(qualified.utf8))
        return renamed
    }
}
