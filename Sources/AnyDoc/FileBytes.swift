// File reading via POSIX calls: the library depends on the Swift stdlib and
// the platform libc only (the same baseline Rust's std sits on), never on
// Foundation.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

func readFile(_ path: String) throws -> [UInt8] {
    let fd = open(path, O_RDONLY)
    if fd < 0 {
        throw ConvertError.io(ioError())
    }
    defer { close(fd) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            throw ConvertError.io(ioError())
        }
        if n == 0 { break }
        bytes.append(contentsOf: buffer[..<n])
    }
    return bytes
}

private func ioError() -> IOError {
    let code = errno
    let detail = strerror(code).map { String(cString: $0) } ?? "unknown error"
    return IOError(errno: code, detail: detail)
}
