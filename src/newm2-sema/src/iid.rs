//! COM IID (interface GUID) parsing for the OO/COM layer. `INTERFACE` types
//! carry an IID string (`["xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"]`); GUARD /
//! ISMEMBER on an interface lower to `QueryInterface`, which needs the IID in
//! its 16-byte in-memory layout. Validated at the interface declaration so a
//! malformed IID is a compile error, never a silently-dead `QueryInterface`.

/// Parse a COM IID string into its 16-byte in-memory GUID layout.
///
/// The string is `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (5 hex groups of
/// 8-4-4-4-12 digits, optionally `{}`-wrapped). The layout is **mixed-endian**:
/// the first three groups are stored little-endian (`u32`, `u16`, `u16`); the
/// last two groups (the 2-byte clock-seq + 6-byte node) are stored exactly as
/// written. E.g. `IID_IUnknown` `00000000-0000-0000-C000-000000000046`
/// → `[00 00 00 00 00 00 00 00 C0 00 00 00 00 00 00 46]`.
pub fn iid_str_to_le16(s: &str) -> Result<[u8; 16], String> {
    let t = s.trim().trim_start_matches('{').trim_end_matches('}');
    let groups: Vec<&str> = t.split('-').collect();
    if groups.len() != 5 {
        return Err(format!("IID must be 5 dash-separated hex groups: {s:?}"));
    }
    for (g, &len) in groups.iter().zip(&[8usize, 4, 4, 4, 12]) {
        if g.len() != len || !g.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("malformed IID group {g:?} in {s:?}"));
        }
    }
    let hex = |g: &str| u64::from_str_radix(g, 16).map_err(|e| e.to_string());
    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&(hex(groups[0])? as u32).to_le_bytes());
    out[4..6].copy_from_slice(&(hex(groups[1])? as u16).to_le_bytes());
    out[6..8].copy_from_slice(&(hex(groups[2])? as u16).to_le_bytes());
    // groups 3 (2 bytes) + 4 (6 bytes): big-endian, as written.
    let tail = |g: &str, out: &mut [u8]| -> Result<(), String> {
        for (i, slot) in out.iter_mut().enumerate() {
            *slot = u8::from_str_radix(&g[i * 2..i * 2 + 2], 16).map_err(|e| e.to_string())?;
        }
        Ok(())
    };
    tail(groups[3], &mut out[8..10])?;
    tail(groups[4], &mut out[10..16])?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iunknown_layout() {
        // The canonical IID_IUnknown, in memory.
        let got = iid_str_to_le16("00000000-0000-0000-C000-000000000046").unwrap();
        assert_eq!(
            got,
            [0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]
        );
        // lowercase + brace-wrapped accepted, same result.
        assert_eq!(iid_str_to_le16("{00000000-0000-0000-c000-000000000046}").unwrap(), got);
    }

    #[test]
    fn mixed_endian_fields() {
        // Distinct bytes per field to pin the endianness.
        let g = iid_str_to_le16("01020304-0506-0708-090A-0B0C0D0E0F10").unwrap();
        assert_eq!(&g[0..4], &[0x04, 0x03, 0x02, 0x01]); // d1 LE
        assert_eq!(&g[4..6], &[0x06, 0x05]); // d2 LE
        assert_eq!(&g[6..8], &[0x08, 0x07]); // d3 LE
        assert_eq!(&g[8..16], &[0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]); // as-written
    }

    #[test]
    fn rejects_malformed() {
        assert!(iid_str_to_le16("not-an-iid").is_err());
        assert!(iid_str_to_le16("00000000-0000-0000-c000").is_err());
        assert!(iid_str_to_le16("0000000g-0000-0000-c000-000000000046").is_err());
    }
}
