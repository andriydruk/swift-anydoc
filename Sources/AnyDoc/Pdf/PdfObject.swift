/// The PDF object model (ISO 32000-1 §7.3), shaped after the `lopdf` types
/// anydoc's PDF stack is built on.
///
/// Reals are `Float`, not `Double`: `lopdf` stores them as `f32`, and the
/// coordinates that flow from here into layout decisions inherit that
/// precision. Widening would change rounding at the boundaries the layout
/// heuristics compare against.

/// An indirect object's identity: object number and generation.
struct PdfObjectId: Hashable {
    var number: UInt32
    var generation: UInt16
}

/// How a string was written. Kept because it survives into the text layer:
/// a hex string and a literal string with the same bytes are the same value,
/// but round-tripping and some heuristics look at the form.
enum PdfStringFormat {
    case literal
    case hexadecimal
}

/// A PDF stream: its dictionary and its raw (still-encoded) bytes.
struct PdfStream {
    var dict: PdfDictionary
    /// The bytes as they appear in the file, before any filter is applied.
    var content: [UInt8]
    /// Where the stream data began, for streams whose `/Length` could not be
    /// resolved while parsing and must be recovered by scanning.
    var startPosition: Int?

    init(dict: PdfDictionary, content: [UInt8] = [], startPosition: Int? = nil) {
        self.dict = dict
        self.content = content
        self.startPosition = startPosition
    }
}

/// A dictionary, insertion-ordered. Order is not semantic in PDF, but keeping
/// it makes parses reproducible and diffs stable — the port's rule against
/// unordered iteration reaching output (PLAN §2, gotcha 3).
struct PdfDictionary {
    private(set) var keys: [[UInt8]] = []
    private var storage: [[UInt8]: PdfObject] = [:]

    init() {}

    subscript(key: [UInt8]) -> PdfObject? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else {
                storage[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }

    subscript(key: String) -> PdfObject? {
        get { self[Array(key.utf8)] }
        set { self[Array(key.utf8)] = newValue }
    }

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    /// Entries in insertion order.
    var entries: [(key: [UInt8], value: PdfObject)] {
        keys.compactMap { key in storage[key].map { (key: key, value: $0) } }
    }
}

indirect enum PdfObject {
    case null
    case boolean(Bool)
    case integer(Int64)
    case real(Float)
    case name([UInt8])
    case string([UInt8], PdfStringFormat)
    case array([PdfObject])
    case dictionary(PdfDictionary)
    case stream(PdfStream)
    case reference(PdfObjectId)
}

extension PdfObject {
    var asInteger: Int64? {
        switch self {
        case .integer(let v): return v
        default: return nil
        }
    }

    /// A number in either form. PDF freely mixes them where a real is meant.
    var asNumber: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .real(let v): return Double(v)
        default: return nil
        }
    }

    var asName: [UInt8]? {
        switch self {
        case .name(let v): return v
        default: return nil
        }
    }

    var asArray: [PdfObject]? {
        switch self {
        case .array(let v): return v
        default: return nil
        }
    }

    /// The dictionary of a dictionary object *or* of a stream — callers that
    /// want `/Type` or `/Length` do not care which they were handed.
    var asDictionary: PdfDictionary? {
        switch self {
        case .dictionary(let d): return d
        case .stream(let s): return s.dict
        default: return nil
        }
    }

    var asStream: PdfStream? {
        switch self {
        case .stream(let s): return s
        default: return nil
        }
    }

    var asReference: PdfObjectId? {
        switch self {
        case .reference(let id): return id
        default: return nil
        }
    }

    var asStringBytes: [UInt8]? {
        switch self {
        case .string(let v, _): return v
        default: return nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
