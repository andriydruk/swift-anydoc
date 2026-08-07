/// Recovery and skipped-content events, reported without changing conversion
/// behavior. Placeholder for a pluggable handler; messages are not a stable
/// API (mirrors the Rust crate's use of the `log` facade).
enum Log {
    static func warn(_ message: @autoclosure () -> String) {}
    static func debug(_ message: @autoclosure () -> String) {}
}
