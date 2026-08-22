/* The system zlib, exposed to Swift as the `CZlib` module.
 *
 * zlib ships with macOS, the iOS SDK and every mainstream Linux, so this is a
 * link against something already present rather than a fetched dependency:
 * `Package.swift` still declares no `.package(...)`.
 */
#include <zlib.h>
