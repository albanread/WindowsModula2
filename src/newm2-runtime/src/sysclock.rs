//! Runtime backing for ISO `SysClock`.
//!
//! Exposes a single shim `nm2_sysclock_now` that fills a Modula-2
//! `DateTime` record (layout frozen by `library/isodef/SysClock.def`).
//! The Modula-2 `SysClock.mod` calls this from `GetClock`.
//!
//! Layout of `DateTime` (matches isodef/SysClock.def):
//!
//!   ```text
//!   year:           CARDINAL  (8 bytes)
//!   month:          [1..12]   (8 bytes, padded)
//!   day:            [1..31]   (8 bytes)
//!   hour:           [0..23]   (8 bytes)
//!   minute:         [0..59]   (8 bytes)
//!   second:         [0..59]   (8 bytes)
//!   fractions:      [0..99]   (8 bytes)
//!   zone:           [-780..720] (8 bytes — signed)
//!   SummerTimeFlag: BOOLEAN   (1 byte, padded to 8 for record alignment)
//!   ```
//!
//! NewM2 packs scalars in declared order with 8-byte alignment per
//! field (codegen-emit_record), so the record total is 9 × 8 = 72 bytes.
//! `nm2_sysclock_now` writes the live values into the slots.

use std::time::SystemTime;

/// Byte offsets of each DateTime field within the M2 record, taken from
/// NewM2's codegen rules (every scalar gets its natural alignment).
/// Codegen emits the LLVM struct type `{ i64 x 8, i1 }`; the i1 trailing
/// flag lives in byte 64 with one byte of usable storage.
const OFFS_YEAR:        usize = 0;
const OFFS_MONTH:       usize = 8;
const OFFS_DAY:         usize = 16;
const OFFS_HOUR:        usize = 24;
const OFFS_MINUTE:      usize = 32;
const OFFS_SECOND:      usize = 40;
const OFFS_FRACTIONS:   usize = 48;
const OFFS_ZONE:        usize = 56;
const OFFS_SUMMER_FLAG: usize = 64;

fn is_leap(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

const DAYS_PER_MONTH: [u32; 13] = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/// Convert a Unix epoch-seconds value to a broken-down date/time in UTC.
/// Returns `(year, month, day, hour, minute, second)`.
fn unix_to_utc(mut secs: i64) -> (u64, u64, u64, u64, u64, u64) {
    let day_secs = 86_400i64;
    let mut days = secs.div_euclid(day_secs);
    secs = secs.rem_euclid(day_secs);
    let hour = (secs / 3600) as u64;
    let minute = ((secs / 60) % 60) as u64;
    let second = (secs % 60) as u64;

    // Anchor: 1970-01-01 was a Thursday; we don't need day-of-week here.
    // Walk forward year-by-year from 1970. This loop runs ~60 iterations
    // for current dates — cheap enough we don't bother with a closed-form
    // (Howard Hinnant's date arithmetic would be faster, but unnecessary
    // for a clock that's called once per `GetClock`).
    let mut year: u64 = 1970;
    loop {
        let yd = if is_leap(year) { 366 } else { 365 };
        if days < yd as i64 {
            break;
        }
        days -= yd as i64;
        year += 1;
    }
    // Negative offsets shouldn't happen for a sane system clock,
    // but if they do we keep walking backwards.
    while days < 0 {
        year -= 1;
        let yd = if is_leap(year) { 366 } else { 365 };
        days += yd as i64;
    }

    let mut month: u64 = 1;
    let mut days_left = days as u32;
    loop {
        let dpm = if month == 2 && is_leap(year) {
            29
        } else {
            DAYS_PER_MONTH[month as usize]
        };
        if days_left < dpm {
            break;
        }
        days_left -= dpm;
        month += 1;
    }
    let day = (days_left + 1) as u64;
    (year, month, day, hour, minute, second)
}

/// Fill `*out` with the current wall-clock time. Always UTC (zone=0,
/// SummerTimeFlag=FALSE) — local-time conversion would need a
/// timezone-database dependency we don't have yet. Programs that need
/// local time can read the system's TZ offset separately and adjust.
/// Bound to `NM2.SysClock.Now`.
///
/// Writes fields individually at their known offsets so the trailing
/// `SummerTimeFlag` (i1, one byte of storage) doesn't get clobbered
/// by `repr(C)` padding rules.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_sysclock_now(out: *mut u8) {
    if out.is_null() {
        return;
    }
    let now = SystemTime::now();
    let (secs, nanos) = match now.duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => (d.as_secs() as i64, d.subsec_nanos()),
        Err(e) => (-(e.duration().as_secs() as i64), 0),
    };
    let (year, month, day, hour, minute, second) = unix_to_utc(secs);
    let fractions = ((nanos / 10_000_000) as u64).min(99);
    unsafe {
        std::ptr::write(out.add(OFFS_YEAR).cast::<u64>(), year);
        std::ptr::write(out.add(OFFS_MONTH).cast::<u64>(), month);
        std::ptr::write(out.add(OFFS_DAY).cast::<u64>(), day);
        std::ptr::write(out.add(OFFS_HOUR).cast::<u64>(), hour);
        std::ptr::write(out.add(OFFS_MINUTE).cast::<u64>(), minute);
        std::ptr::write(out.add(OFFS_SECOND).cast::<u64>(), second);
        std::ptr::write(out.add(OFFS_FRACTIONS).cast::<u64>(), fractions);
        std::ptr::write(out.add(OFFS_ZONE).cast::<i64>(), 0i64);
        std::ptr::write(out.add(OFFS_SUMMER_FLAG).cast::<u8>(), 0u8);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_epoch_decodes_to_1970_01_01() {
        assert_eq!(unix_to_utc(0), (1970, 1, 1, 0, 0, 0));
    }

    #[test]
    fn one_day_later_decodes_to_jan_2() {
        assert_eq!(unix_to_utc(86_400), (1970, 1, 2, 0, 0, 0));
    }

    #[test]
    fn leap_day_2024_decodes_correctly() {
        // 2024-02-29 00:00:00 UTC = 1709164800.
        assert_eq!(unix_to_utc(1_709_164_800), (2024, 2, 29, 0, 0, 0));
    }

    #[test]
    fn march_1_after_leap_day() {
        assert_eq!(unix_to_utc(1_709_251_200), (2024, 3, 1, 0, 0, 0));
    }

    #[test]
    fn pre_y2k_decodes_correctly() {
        // 1999-12-31 23:59:59 UTC = 946684799.
        assert_eq!(unix_to_utc(946_684_799), (1999, 12, 31, 23, 59, 59));
    }
}
