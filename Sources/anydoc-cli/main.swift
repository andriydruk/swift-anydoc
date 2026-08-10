// Minimal CLI over the AnyDoc library: file in, Markdown out. Exists for the
// differential harness (Rust anydoc CLI vs this) and ad-hoc use.
import AnyDoc
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Write to a file descriptor directly rather than through `stdout` and
/// `stderr`.
///
/// On Linux those are mutable globals, which Swift 6's strict concurrency
/// checking rejects as shared mutable state. Darwin imports them differently,
/// so this only ever failed on Linux — and only once CI actually ran there.
/// Writing to the descriptor sidesteps the globals and is portable.
func write(_ text: String, to descriptor: Int32) {
    var bytes = Array(text.utf8)[...]
    while !bytes.isEmpty {
        let written = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        // A short write is normal on a pipe; anything else is unrecoverable
        // and silence is the only option left.
        if written <= 0 { return }
        bytes = bytes.dropFirst(written)
    }
}

func fail(_ message: String) -> Never {
    write(message + "\n", to: 2)
    exit(1)
}

func readBytes(_ path: String) -> [UInt8]? {
    let fd = open(path, O_RDONLY)
    if fd < 0 { return nil }
    defer { close(fd) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        bytes.append(contentsOf: buffer[..<n])
    }
    return bytes
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: anydoc-cli <file> [--format <name>]")
}
let path = args[1]
var format: Format? = nil
if let i = args.firstIndex(of: "--format"), i + 1 < args.count {
    guard let named = Format(extension: args[i + 1]) else {
        fail("unknown format: \(args[i + 1])")
    }
    format = named
}

do {
    let markdown: String
    if let format {
        guard let bytes = readBytes(path) else { fail("cannot read \(path)") }
        markdown = try AnyDoc.markdown(bytes, format: format)
    } else {
        markdown = try AnyDoc.markdown(contentsOf: path)
    }
    write(markdown, to: 1)
} catch let error as ConvertError {
    fail("ERROR(\(error.code)): \(error.message)")
}
