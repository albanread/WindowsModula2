//! Disk-file I/O shims backing ISO `StreamFile`, `SeqFile`, `RndFile`.
//!
//! Each open file is a `std::fs::File` boxed and addressed by its raw
//! pointer cast to `u64` — the M2 side carries this as an opaque
//! `CARDINAL64` handle inside the device-table extension slot.
//!
//! All shims are bound under `NM2.File.*` (see newm2-llvm/src/lib.rs).
//! Errors are reported by handle = 0 (Open) or by a non-zero status
//! code through `*VAR res` parameters on read/write.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};

/// Open-flag bits the M2 side passes in. Stay in sync with the
/// `FileFlags` set in the rtdef.
pub mod flags {
    pub const READ:  u64 = 1 << 0;
    pub const WRITE: u64 = 1 << 1;
    pub const OLD:   u64 = 1 << 2;  // must exist
    pub const NEW:   u64 = 1 << 3;  // create / truncate
}

/// Box-leak a File and return its address as a 64-bit handle.
fn handle_of(f: File) -> u64 {
    Box::into_raw(Box::new(f)) as u64
}

/// Reconstruct a `&mut File` from a handle. Returns `None` for 0
/// (the "no handle" sentinel).
unsafe fn handle_to<'a>(h: u64) -> Option<&'a mut File> {
    if h == 0 {
        None
    } else {
        Some(unsafe { &mut *(h as *mut File) })
    }
}

/// `NM2.File.Open(name_ptr, flags) -> handle (0 on error)`
///
/// `name_ptr` is a NUL-terminated path. `flags` is a bitset (see
/// `flags`). The caller decides read/write/old/new semantics.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_open(
    name_ptr: *const u16,
    flags_bits: u64,
) -> u64 {
    if name_ptr.is_null() {
        return 0;
    }
    // M2 `ARRAY OF CHAR` is wide (UTF-16); read a wide NUL-terminated path.
    // (Reading it as a narrow C string truncated every name to its first
    // character, since ASCII code units have a 0x00 high byte.)
    let mut len = 0usize;
    while unsafe { *name_ptr.add(len) } != 0 {
        len += 1;
    }
    let units = unsafe { std::slice::from_raw_parts(name_ptr, len) };
    let name = match String::from_utf16(units) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let mut opts = OpenOptions::new();
    let read = flags_bits & flags::READ != 0;
    let write = flags_bits & flags::WRITE != 0;
    let old = flags_bits & flags::OLD != 0;
    let new = flags_bits & flags::NEW != 0;
    if read {
        opts.read(true);
    }
    if write {
        opts.write(true);
    }
    if new {
        // truncate-or-create
        opts.create(true).truncate(true);
    } else if !old && write {
        // default for write without OLD: create-if-missing, don't
        // truncate (matches XDS "append"-leaning semantics; the
        // device-table layer seeks to 0 after open anyway).
        opts.create(true);
    }
    match opts.open(name) {
        Ok(f) => handle_of(f),
        Err(_) => 0,
    }
}

/// `NM2.File.Close(handle)`
///
/// Releases the underlying file. A zero handle is a no-op.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_close(h: u64) {
    if h == 0 {
        return;
    }
    let _ = unsafe { Box::from_raw(h as *mut File) };
}

/// `NM2.File.Read(handle, addr, max) -> bytes_read`
///
/// Returns 0 on EOF or error. The M2 side reports `endOfInput` when
/// `bytes_read = 0` AND a subsequent `Eof(handle)` returns TRUE.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_read(
    h: u64,
    addr: *mut u8,
    max: u64,
) -> u64 {
    if addr.is_null() || max == 0 {
        return 0;
    }
    let Some(f) = (unsafe { handle_to(h) }) else {
        return 0;
    };
    let buf = unsafe { std::slice::from_raw_parts_mut(addr, max as usize) };
    match f.read(buf) {
        Ok(n) => n as u64,
        Err(_) => 0,
    }
}

/// `NM2.File.Write(handle, addr, n) -> bytes_written`
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_write(
    h: u64,
    addr: *const u8,
    n: u64,
) -> u64 {
    if addr.is_null() || n == 0 {
        return 0;
    }
    let Some(f) = (unsafe { handle_to(h) }) else {
        return 0;
    };
    let buf = unsafe { std::slice::from_raw_parts(addr, n as usize) };
    match f.write_all(buf) {
        Ok(()) => n,
        Err(_) => 0,
    }
}

/// `NM2.File.WriteText(handle, addr, n) -> chars_written`
///
/// Wide text path: `addr` is `n` CHAR cells (UTF-16); they are encoded as
/// UTF-8 and written. Returns `n` on success, 0 on error. (RawIO uses the
/// byte-oriented `nm2_file_write` instead.)
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_write_text(h: u64, addr: *const u16, n: u64) -> u64 {
    if addr.is_null() || n == 0 {
        return 0;
    }
    let Some(f) = (unsafe { handle_to(h) }) else {
        return 0;
    };
    let units = unsafe { std::slice::from_raw_parts(addr, n as usize) };
    let s = crate::io::render_utf16_units(units);
    match f.write_all(s.as_bytes()) {
        Ok(()) => n,
        Err(_) => 0,
    }
}

/// `NM2.File.ReadText(handle, addr, max) -> chars_read`
///
/// Wide text path: reads bytes, decodes UTF-8, and writes up to `max` UTF-16
/// CHAR cells into `addr` (astral code points become a surrogate pair). This is
/// the inverse of `WriteText` (which UTF-8-encodes), so text round-trips exactly.
/// Returns 0 on EOF/error. Reads in chunks; an incomplete sequence at a chunk
/// boundary is pushed back (via seek) for the next chunk.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_read_text(h: u64, addr: *mut u16, max: u64) -> u64 {
    if addr.is_null() || max == 0 {
        return 0;
    }
    let Some(f) = (unsafe { handle_to(h) }) else {
        return 0;
    };
    let dst = unsafe { std::slice::from_raw_parts_mut(addr, max as usize) };
    let mut written = 0usize;
    let mut buf = [0u8; 4096];
    'outer: while written < dst.len() {
        let nread = match f.read(&mut buf) {
            Ok(0) => break,
            Ok(k) => k,
            Err(_) => break,
        };
        let at_eof = nread < buf.len(); // a short read from a regular file means EOF
        let mut i = 0usize;
        while i < nread {
            if written >= dst.len() {
                let _ = f.seek(SeekFrom::Current(-((nread - i) as i64))); // push back the rest
                break 'outer;
            }
            let b0 = buf[i];
            let seqlen = if b0 < 0x80 {
                1
            } else if b0 >= 0xC0 && b0 < 0xE0 {
                2
            } else if b0 >= 0xE0 && b0 < 0xF0 {
                3
            } else if b0 >= 0xF0 {
                4
            } else {
                1 // stray continuation byte: pass through as Latin-1
            };
            if i + seqlen > nread {
                if at_eof {
                    dst[written] = b0 as u16; // truncated at EOF: emit the byte as-is
                    written += 1;
                    i += 1;
                    continue;
                }
                let _ = f.seek(SeekFrom::Current(-((nread - i) as i64))); // re-read whole char next chunk
                break;
            }
            let cp: u32 = match seqlen {
                1 => b0 as u32,
                2 => (((b0 & 0x1F) as u32) << 6) | ((buf[i + 1] & 0x3F) as u32),
                3 => {
                    (((b0 & 0x0F) as u32) << 12)
                        | (((buf[i + 1] & 0x3F) as u32) << 6)
                        | ((buf[i + 2] & 0x3F) as u32)
                }
                _ => {
                    (((b0 & 0x07) as u32) << 18)
                        | (((buf[i + 1] & 0x3F) as u32) << 12)
                        | (((buf[i + 2] & 0x3F) as u32) << 6)
                        | ((buf[i + 3] & 0x3F) as u32)
                }
            };
            if cp <= 0xFFFF {
                dst[written] = cp as u16;
                written += 1;
            } else {
                if written + 2 > dst.len() {
                    let _ = f.seek(SeekFrom::Current(-((nread - i) as i64)));
                    break 'outer;
                }
                let v = cp - 0x10000;
                dst[written] = (0xD800 + (v >> 10)) as u16;
                dst[written + 1] = (0xDC00 + (v & 0x3FF)) as u16;
                written += 2;
            }
            i += seqlen;
        }
    }
    written as u64
}

/// `NM2.File.Seek(handle, offset) -> 0 on success, !=0 on error`
///
/// Absolute seek from the start of the file. ISO RndFile uses unsigned
/// offsets; negative seek-from-current is not currently exposed.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_seek(h: u64, offset: u64) -> u64 {
    let Some(f) = (unsafe { handle_to(h) }) else {
        return 1;
    };
    match f.seek(SeekFrom::Start(offset)) {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

/// `NM2.File.Tell(handle) -> current offset`
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_tell(h: u64) -> u64 {
    let Some(f) = (unsafe { handle_to(h) }) else {
        return 0;
    };
    f.stream_position().unwrap_or(0)
}

/// `NM2.File.Flush(handle)`
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_flush(h: u64) {
    if let Some(f) = unsafe { handle_to(h) } {
        let _ = f.flush();
    }
}

/// `NM2.File.Size(handle) -> length in bytes`
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_file_size(h: u64) -> u64 {
    let Some(f) = (unsafe { handle_to(h) }) else {
        return 0;
    };
    f.metadata().map(|m| m.len()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Build a wide (UTF-16) NUL-terminated path, as M2 `ARRAY OF CHAR` passes.
    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    #[test]
    fn roundtrip_write_read() {
        // A multi-character path must be honoured in full (read as a wide
        // string, not truncated to its first char).
        let tmp = std::env::temp_dir().join("nm2_file_test.txt");
        let path = wide(tmp.to_str().unwrap());
        let h = unsafe { nm2_file_open(path.as_ptr(), flags::WRITE | flags::NEW) };
        assert_ne!(h, 0);
        let data = b"hello file";
        let n = unsafe { nm2_file_write(h, data.as_ptr(), data.len() as u64) };
        assert_eq!(n, data.len() as u64);
        unsafe { nm2_file_close(h) };

        // The real, full-named file must exist on disk.
        assert!(tmp.exists(), "open must create the file at its full path");

        let h2 = unsafe { nm2_file_open(path.as_ptr(), flags::READ | flags::OLD) };
        assert_ne!(h2, 0);
        let mut buf = [0u8; 32];
        let got = unsafe { nm2_file_read(h2, buf.as_mut_ptr(), buf.len() as u64) };
        assert_eq!(got, data.len() as u64);
        assert_eq!(&buf[..data.len()], data);
        unsafe { nm2_file_close(h2) };
        let _ = std::fs::remove_file(&tmp);
    }
}
