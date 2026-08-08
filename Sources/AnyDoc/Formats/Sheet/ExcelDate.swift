/// Excel serial date/time values and the way anydoc renders them.
///
/// A serial is a day count from the workbook epoch with the time of day as
/// the fractional part. Whether one is a date, a time, or an elapsed duration
/// is decided by the cell's number format (`CellFormat`), not by the value.

/// A cell value the number format marked as temporal.
struct ExcelDateTime {
    var value: Double
    var isDuration: Bool
    /// Workbooks may count from 1904 instead of the usual 1899-12-30 epoch.
    var is1904: Bool
}

/// Milliseconds in a day, the serial's unit scale.
private let msPerDay: Double = 24 * 60 * 60 * 1e3
/// Days between the 1900 and 1904 workbook epochs.
private let epoch1900To1904: Double = 1462
/// 1899-12-30, the 1900-epoch origin, as days from 1970-01-01.
private let excelEpochDays = -25569

/// The civil date and time a serial denotes, or `nil` when it lands outside
/// the representable range (the reference's `checked_add_signed` returning
/// `None`), in which case callers fall back to printing the raw number.
///
/// Reproduces the reference's two quirks: serials below 60 are shifted by a
/// day to absorb Excel's mythical 1900-02-29, and the result is rounded to
/// whole milliseconds before it is split into components.
func excelSerialToCivil(_ dt: ExcelDateTime) -> (
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
)? {
    var serial = dt.is1904 ? dt.value + epoch1900To1904 : dt.value
    serial = serial >= 60.0 ? serial : serial + 1.0
    let msFloat = (serial * msPerDay).rounded()
    guard msFloat.isFinite, msFloat.magnitude < 9.2e18 else { return nil }
    let totalMs = Int(msFloat)

    let msInDay = 86_400_000
    // Floor division: a negative serial is a date before the epoch, not a
    // truncation toward zero.
    var days = totalMs / msInDay
    var remainder = totalMs % msInDay
    if remainder < 0 {
        remainder += msInDay
        days -= 1
    }
    days += excelEpochDays
    // The reference's calendar type tops out a little past ±262000 years.
    guard days > -95_000_000, days < 95_000_000 else { return nil }

    let (year, month, day) = civilFromDays(days)
    let secondOfDay = remainder / 1000
    return (year, month, day, secondOfDay / 3600, (secondOfDay % 3600) / 60, secondOfDay % 60)
}

/// Howard Hinnant's `civil_from_days`: days from 1970-01-01 to a proleptic
/// Gregorian date.
private func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

/// A civil date/time as the reference's calendar type prints it:
/// `YYYY-MM-DD HH:MM:SS`, with years outside `0...9999` carrying an explicit
/// sign. Sub-second digits are never printed here — anydoc discards them as
/// noise from the serial's float.
func formatCivilDateTime(
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
) -> String {
    let yearText: String
    if year >= 0 && year <= 9999 {
        yearText = padZero(year, 4)
    } else {
        yearText = (year < 0 ? "-" : "+") + padZero(abs(year), 4)
    }
    return "\(yearText)-\(padZero(month, 2))-\(padZero(day, 2)) "
        + "\(padZero(hour, 2)):\(padZero(minute, 2)):\(padZero(second, 2))"
}

private func padZero(_ value: Int, _ width: Int) -> String {
    var text = String(value)
    while text.utf8.count < width { text = "0" + text }
    return text
}

/// Render a time-of-day serial (a fraction of a day) as `hh:mm:ss`.
func formatTimeOfDay(_ days: Double) -> String {
    let totalSecs = rustSaturatingUInt64((abs(days) * 86_400.0).rounded()) % 86_400
    return "\(padZero(Int(totalSecs / 3600), 2)):\(padZero(Int((totalSecs % 3600) / 60), 2))"
        + ":\(padZero(Int(totalSecs % 60), 2))"
}

/// Render an Excel duration (stored in days) as `[h]:mm:ss` — the hour field
/// is elapsed time, so it is not wrapped at 24 and is not zero-padded.
func formatDurationDays(_ days: Double) -> String {
    let sign = days < 0.0 ? "-" : ""
    let totalSecs = rustSaturatingUInt64((abs(days) * 86_400.0).rounded())
    return sign + "\(totalSecs / 3600):\(padZero(Int((totalSecs % 3600) / 60), 2))"
        + ":\(padZero(Int(totalSecs % 60), 2))"
}
