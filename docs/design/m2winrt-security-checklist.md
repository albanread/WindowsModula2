# M2WINRT Security & Windows-11 Modernization Checklist

> Source: consolidated from the clean-room ADW modernization sweep
> (`e:/cleanroom/modernization/`: README + cryptography + network-protocols +
> windows-apis + security-hardening), produced for the NewM2 M2WINRT recreation.
> This is the authoritative "what must we deprecate / replace, and when" reference
> for the library build. Each phase must honour the rules that gate it BEFORE the
> affected module ships. See [m2winrt-runtime-library.md](m2winrt-runtime-library.md)
> for the overall library design and phase plan.

I have read all five documents in full. Here is the consolidated, phase-gated checklist.

---

# M2WINRT Recreation Checklist â€” Security & Windows 11 Modernization Sweep

Consolidated from the ADW modernization sweep (README + cryptography + network-protocols + windows-apis + security-hardening). Organized by severity. Every item carries: **Finding Â· Affected ADW module(s) Â· Modern replacement Â· M2WINRT RECREATION RULE Â· Gating build PHASE.**

Phase map (per the task): **P1** = MemUtils/SpecialReals/SortLib/Money Â· **P2** = FormatString/RandomNumbers/TimeFunc Â· **P3** = Win32 helpers (Environment/Registry/FileFunc/Threads) Â· **P4** = crypto Â· **P5** = COM/network.

---

## PHASE 1 VERDICT FIRST (asked for explicitly, stated plainly)

The four Phase-1 modules are almost entirely pure-compute. Decisive per-module ruling:

- **MemUtils â€” HAS a real security obligation.** It is the home of memory-safety and secret-hygiene primitives that everything in P4 depends on. Two hard obligations:
  1. The portable `ZeroMem` / `MoveMemForward` / `MoveMemBackward` are documented as **unimplemented stubs** in ADW (security-hardening F7). Shipping a no-op `ZeroMem` is a latent secret-disclosure bug because crypto code will call it expecting a wipe and get nothing. **Do not ship a stubbed ZeroMem.**
  2. MemUtils must provide a **non-elidable secure-zero** (`SecureZeroMemory` semantics â€” compiler must not dead-store-eliminate it) and ideally a **constant-time compare** for use by P4. These are the contracts the crypto modules (F5, F10, F12) will lean on. This is the one Phase-1 module that is NOT pure-compute. Its overflow/size math (F7) also feeds allocations and must be checked.
- **SpecialReals â€” NONE. Pure compute.** IEEE-754 special-value helpers (NaN/Inf classification, etc.). No randomness, no secrets, no Win32 surface, no DPI/encoding concern. No security or Win11 obligation. The only adjacent platform note (x87â†’SSE2/MXCSR, windows F6) lives in `Float`, not here â€” and even there x64 is already SSE2. SpecialReals carries nothing.
- **SortLib â€” NONE. Pure compute.** Comparison/sort utility. No security obligation. One *correctness* caveat worth a note (not a security finding): if it is ever used to order security-relevant data, comparisons should be ordinary correctness â€” there is no constant-time requirement for a general sort. Treat as pure-compute.
- **Money â€” NONE security-wise; HAS a correctness obligation.** Money has **no** Win11/security obligation (no crypto, no RNG, no Win32). It DOES have a hard **overflow/rounding-correctness** obligation: monetary arithmetic must use checked integer/decimal math with defined rounding (banker's/half-even or stated policy) and must not silently wrap. This is a financial-correctness duty, not a security one â€” but it is real and must not be skipped. (Cross-references the same checked-arithmetic discipline as security-hardening F7, applied to money rather than to allocation sizes.)

**Net for Phase 1:** Only **MemUtils** gates on a genuine security/platform obligation (SecureZero + working ZeroMem + constant-time compare + checked size math). **Money** gates on financial-correctness (overflow/rounding). **SpecialReals** and **SortLib** are pure-compute with no obligation â€” build them, test them, move on.

---

## ðŸ”´ CRITICAL â€” fix now (gate the phases they live in)

### C1. Security randomness from a non-CSPRNG (clock-seeded lagged-Fibonacci) â€” Gates **Phase 2 (RandomNumbers)**; blocks **Phase 4**
- **Finding:** Both ADW PRNGs are 55-word lagged-Fibonacci generators, seedable to a fully reproducible stream and otherwise seeded from wall clock + PID/TID (~tens of bits of real entropy). ADW wires this straight into RSA prime generation, OAEP seeds, and PSS salts. Predictable primes â‡’ recoverable private keys; predictable seeds/salts/IVs/nonces â‡’ total break. (crypto F9; README Critical #1)
- **Affected ADW modules:** `RandomNumbers`, `RealRandomNumbers`, and security consumers `VLI` (`GetRandom`/`GetRandomSmaller`/`GetPrime`), `CryptEncode` (`GetRandomNormal`).
- **Modern replacement:** `BCryptGenRandom(BCRYPT_USE_SYSTEM_PREFERRED_RNG)` for ALL security randomness (keys, primes, IVs, nonces, salts, OAEP seeds, PSS salts).
- **RECREATION RULE:** Do **NOT** ship the lagged-Fibonacci PRNG as a security RNG. In Phase 2, expose `RandomNumbers` only as an explicitly-named **non-crypto utility** (simulation/sampling/test data). Provide a **separate CSPRNG module** backed by a `BCryptGenRandom` binding, and build a hard API guardrail so no crypto path (P4) can reach the lagged-Fibonacci generator. RandomNumbers must carry a "NOT FOR SECURITY" contract in its interface. This is the single highest-impact decision in the whole library â€” get it right at Phase 2 so Phase 4 inherits a clean RNG.

### C2. SMTP sends mail in cleartext on port 25 (no TLS / no AUTH / no MIME) â€” Gates **Phase 5 (network)**
- **Finding:** RFC-821 client hard-coded to TCP :25, plaintext; the doc states "No TLS, no authentication, no MIME." Every byte and any future credential is on the wire. Also carries protocol-correctness defects: un-bracketed MAIL FROM/RCPT TO, first-line-only multi-line reply parsing (desyncs on modern EHLO), no dot-stuffing, no timezone, literal Bcc leaked into body. (net F1; README Critical #2)
- **Affected ADW modules:** `SMTP` (on `Socket`).
- **Modern replacement:** Submission over implicit TLS :465 (SMTPS) or STARTTLS :587 via **Schannel (SSPI)**; **SMTP AUTH via SASL**, PLAIN/LOGIN only inside TLS, **XOAUTH2/OAuth2 bearer** for M365 & Gmail (both have disabled basic auth); **MIME** bodies; ESMTP `EHLO`. Preferred M365 path: **Microsoft Graph `sendMail`** over WinHTTP+TLS.
- **RECREATION RULE:** Do **NOT** recreate a cleartext :25 SMTP client. In Phase 5, build SMTP on top of the Phase-5 TLS socket (C5/H6) only; default to :587 STARTTLS or :465 implicit TLS; fix the multi-line-reply parser and dot-stuffing while rewriting. Keep cleartext only behind an explicit "internal relay" flag, never the default. Strongly prefer the Graph `sendMail` path for M365.

### C3. Shell command injection via `%COMSPEC% /C <string>` â€” Gates **Phase 3 (Win32 helpers: Environment/process launch)**
- **Finding:** `RunProg.PerformCommand` hands the entire command string to `cmd.exe /C`, so any attacker-influenced substring is shell-interpreted (`& | > < ^ %`, `%VAR%` expansion, `for`/`if`). Canonical command-injection sink. A second issue: it trusts `%COMSPEC%`/bare `CMD.EXE` as the interpreter (sec F9). (sec F1; README Critical #3)
- **Affected ADW modules:** `RunProg` (`PerformCommand`, `DoIt`); env lookup via `Environment`.
- **Modern replacement:** `CreateProcessW` directly, no shell; program as application-name, command line built with correct `CommandLineToArgvW` quoting. If a shell is truly required, treat the payload as data (escape/reject `& | < > ^ " % ( ) ! \n`) â€” documented fallback only. Resolve `cmd.exe` to its full `System32` path, never trust `%COMSPEC%` blindly.
- **RECREATION RULE:** Do **NOT** provide a "run this string through the shell" convenience by default. In Phase 3, the primary process-launch API takes **(program, argv array)** and calls `CreateProcessW` with no shell. Any shell variant is opt-in, separately named, and escapes/validates its input. Resolve the interpreter to `%SystemRoot%\System32\cmd.exe`.

---

## ðŸŸ  HIGH â€” fix soon

### H1. Over-broad handle inheritance (`bInheritHandles = TRUE`) â€” Gates **Phase 3 (process launch)** and **Phase 5 (PipedExec)**
- **Finding:** Both `RunProg` and `PipedExec` call `CreateProcess` with process-wide `bInheritHandles=TRUE`; the child inherits *every* inheritable handle, not just the intended pipe ends. RunProg does no redirection at all yet still passes TRUE â€” pure attack surface. (sec F2)
- **Affected ADW modules:** `PipedExec`, `RunProg`.
- **Modern replacement:** `STARTUPINFOEX` + `InitializeProcThreadAttributeList` + `UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_HANDLE_LIST, â€¦)` listing only the intended handles; `EXTENDED_STARTUPINFO_PRESENT`; mark exactly those handles inheritable via `SetHandleInformation`. For RunProg (no redirection): pass `bInheritHandles = FALSE`.
- **RECREATION RULE:** Never recreate a launch helper with blanket `bInheritHandles=TRUE`. P3 RunProg launches with `FALSE`. P5 PipedExec uses an explicit handle allowlist (`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`) and inherits only the pipe ends; keep the parent-closes-its-copies EOF discipline.

### H2. DLL search-order hijacking (bare `LoadLibrary`) â€” Gates **Phase 0/startup, surfaces in Phase 5 (COM/UI bindings)**
- **Finding:** `HTMLHELP` (`hhctrl.ocx`), `SimpleMAPI` (`MAPI32.DLL`), `RichEdit` (`Riched20/32`), `Gdiplus`/`GdiplusFlat` resolve their DLL by bare name â†’ DLL planting / search-order hijack â†’ in-process code execution on first feature use. (sec F3)
- **Affected ADW modules:** `HTMLHELP`, `SimpleMAPI`, `RichEdit`, `Gdiplus`, `GdiplusFlat`.
- **Modern replacement:** Call `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32)` + `SetDllDirectory("")` at startup; load each DLL via `LoadLibraryExW(name, NULL, LOAD_LIBRARY_SEARCH_SYSTEM32)` or full `GetSystemDirectoryW` path.
- **RECREATION RULE:** Any M2WINRT dynamic-load thunk must load by full System32 path or `LoadLibraryEx(...SEARCH_SYSTEM32)` â€” bare-name `LoadLibrary` is banned. Add the `SetDefaultDllDirectories` + `SetDllDirectory("")` calls to the library's one-time process-init path (land early, before Phase 5 bindings exist).

### H3. NULL-DACL named IPC objects (any local user can open) + pipe-squat â€” Gates **Phase 5 (NamedPipes/MemShare/FileMap)**
- **Finding:** `NamedPipes`, `MemShare`, `FileMap` build objects with `SetSecurityDescriptorDacl(sd, TRUE, NIL, FALSE)` = NULL DACL (Everyone full access); pipes also lack `FILE_FLAG_FIRST_PIPE_INSTANCE`; names are predictable (`<name>_SM_MEM`, `\\.\PIPE\<name>`); pipe client supports remote `\\Server\PIPE\â€¦`. MemShare's lock lives *in* the shared region, so a hostile opener can subvert the mutex directly. (sec F4; net F6)
- **Affected ADW modules:** `NamedPipes`, `MemShare`, `FileMap`.
- **Modern replacement:** Explicit least-privilege DACL (SDDL via `ConvertStringSecurityDescriptorToSecurityDescriptorW`); `Local\` namespace (not `Global\`); `FILE_FLAG_FIRST_PIPE_INSTANCE`; mandatory integrity label (`SDDL_NO_WRITE_UP`); peer validation (`GetNamedPipeClientProcessId`, careful `ImpersonateNamedPipeClient` reading one message first).
- **RECREATION RULE:** Never recreate these with a NULL DACL. In Phase 5, every named IPC object gets an explicit least-privilege DACL, `Local\` namespace by default, `FILE_FLAG_FIRST_PIPE_INSTANCE` on first create, and an integrity label. Validate the peer before trusting it. Default to local-only; remote is opt-in.

### H4. Secrets not zeroized / not lockable in memory â€” Gates **Phase 4 (crypto)**; depends on **Phase 1 (MemUtils)**
- **Finding:** Cipher key schedules, IVs, RSA private exponents (`d/dp/dq/qInv`), primes `p/q`, VLI limb buffers, and CryptKey stack buffers are freed with ordinary deallocation (non-debug `DeallocateEx` doesn't even overwrite). Secrets linger in freed heap, dead stack frames, pagefile, and â€” critically â€” SYSTEMEX's PMD walks committed memory and writes it to disk. Naive `memset` may be dead-store-eliminated. (sec F5; crypto F12)
- **Affected ADW modules:** `AES`, `DES`, `Blowfish`, `AreSee4`, `RSA`, `VLI`, `CryptKey`.
- **Modern replacement:** `SecureZeroMemory` (non-elidable) over every key/IV/schedule/password/limb buffer immediately before free; `VirtualLock` long-lived secrets (RSA private key, master keys); DPAPI (`CryptProtectMemory`/`CryptProtectData`) at rest; exclude crypto buffers from any crash/PMD dump.
- **RECREATION RULE:** Provide the non-elidable secure-zero in **Phase 1 MemUtils** (see Phase-1 verdict), then in **Phase 4** every cipher/hash/RSA `Destroy` and every KDF routine must scrub its secrets via that helper before free. Add a "sensitive" dispose path to VLI that zeroes `digits[0..used-1]`. Do NOT rely on `MemUtils.FillMemBYTE`/portable `ZeroMem` for this. If the M2WINRT runtime keeps a PMD/crash-dump facility, exclude or scrub crypto buffers.

### H5. No exploit-mitigation build flags / no manifest; SYSTEMEX vs CFG/CET â€” Gates **all phases (build/link/manifest)**; SYSTEMEX is a tracked porting workstream
- **Finding:** Binaries lack ASLR/DEP/CFG/CET/stack-cookies markings and a hardened manifest. SYSTEMEX implements manual FS:[0] SEH (x86) / custom "ADW Soft" scope tables (x64) with return-address rewriting (`HackReraiseReturnAddress`, âˆ’5 adjustments) â€” which **conflicts with CFG indirect-call validation and CET shadow stacks**. (sec F6; README note on runtime)
- **Affected ADW modules:** all DLLs/EXEs; runtime `SYSTEMEX` is the compatibility concern.
- **Modern replacement:** Link/post-mark `/DYNAMICBASE /HIGHENTROPYVA /NXCOMPAT /GS /SAFESEH`; `/guard:cf` and `/CETCOMPAT` only after a SYSTEMEX audit; `editbin`/`setdllcharacteristics` if the toolchain can't emit bits; ship a manifest (`asInvoker`, PerMonitorV2, longPathAware, UTF-8 active code page, ComCtl32 v6, Win10/11 supportedOS); Authenticode-sign + timestamp.
- **RECREATION RULE:** Bake ASLR/DEP/GS/HIGHENTROPYVA, the hardened manifest, and code-signing into the **NewM2 build/link** for M2WINRT from Phase 1 onward (these are low-risk and should be the default for every emitted binary). **Gate `/guard:cf` and `/CETCOMPAT` behind a dedicated exception-runtime port** â€” if NewM2's exception model also rewrites return addresses, treat shadow-stack/CFG compatibility as a real porting task, not a flag flip. Prefer x64 (table-based SEH) over x86. NOTE: M2WINRT runs on NewM2, not the ADW toolchain â€” re-verify what NewM2 emits rather than assuming ADW's SEH machinery.

### H6. No transport security on raw sockets â€” Gates **Phase 5 (Socket/SMTP and any future client)**
- **Finding:** `Socket` is a thin Winsock-2 wrapper with no TLS/SSPI/cert handling; every consumer is exposed to eavesdropping/MITM/downgrade with no server authentication. (net F2)
- **Affected ADW modules:** `Socket` (and all consumers).
- **Modern replacement:** TLS 1.2/1.3 via **Schannel (SSPI)**: `AcquireCredentialsHandle` â†’ `InitializeSecurityContextW` loop â†’ `QueryContextAttributes` (stream sizes + server cert) â†’ `EncryptMessage`/`DecryptMessage`. Enforce chain validation (`CertGetCertificateChain` + `CertVerifyCertificateChainPolicy` / `CERT_CHAIN_POLICY_SSL`), SNI, explicit hostname/SAN match, disable SSL2/3 + TLS1.0/1.1, **fail closed**, optional pinning.
- **RECREATION RULE:** In Phase 5, build a `SecureSocket` TLS module (Schannel) exposing the same `Send`/`Receive`/`Close` shape as the raw socket so SMTP and future clients switch with minimal change. Validation errors abort by default (fail closed). One TLS shim secures every current and future consumer â€” build it before any networked client.

### H7. Broken/weak crypto primitives at the API surface â€” Gates **Phase 4 (crypto)**
Grouped (each is its own High in the source, same recreation discipline):
- **H7a. MD5** (collision-broken, crypto F1) â€” module `MD5` â†’ SHA-256/384/512, SHA-3, BLAKE2/3 via `BCryptHashData`.
- **H7b. SHA-1** (SHATTERED, NIST-deprecated, crypto F2) â€” `SHA1` (and transitively `HMAC`, `CryptKey` PBKDF2, `CryptEncode` OAEP/PSS/MGF1, `RSA`) â†’ SHA-256+. This is the keystone change â€” re-instantiate HMAC, PBKDF2 PRF, and OAEP/PSS/MGF1 over SHA-256.
- **H7c. RC4** (broken, RFC-7465 banned; ADW omits the initial-byte drop, `Reset` reuses keystream â€” catastrophic, crypto F3) â€” `AreSee4` â†’ AES-256-GCM / ChaCha20-Poly1305.
- **H7d. 64-bit-block ciphers / 56-bit DES key (Sweet32, crypto F4)** â€” `DES`, `Blowfish` â†’ AES-256 (128-bit block).
- **H7e. No AEAD â€” only unauthenticated ECB/CBC/CFB (crypto F5)** â€” `AES`, `DES`, `Blowfish` â†’ AES-256-GCM (`BCRYPT_AES_GCM`) with nonce+AAD+tag, or encrypt-then-HMAC; remove ECB from the public surface.
- **RECREATION RULE (all of H7):** Re-platform Phase-4 crypto onto **CNG (`bcrypt.dll`/`ncrypt.dll`)** â€” do NOT re-implement these primitives in M2. Make MD5/SHA-1-for-security/RC4/single-DES/3DES default-OFF and reachable only behind explicitly-named "insecure/legacy verify-or-decrypt-only" shims for migrating historical data. Default symmetric encryption to **AES-256-GCM**; never expose ECB. Version every container/wire format (block size 8â†’16, +12-byte nonce, +16-byte tag) so legacy data still decrypts during transition, then re-encrypt opportunistically.

### H8. No high-DPI awareness (Per-Monitor-V2) â€” Gates **Phase 5 / UI phase (WinShell/DlgShell)** â€” out of P1â€“P5 core scope but tracked
- **Finding:** Framework reads DPI once at init, no `WM_DPICHANGED`, no awareness declaration â†’ compositor bitmap-stretches on mixed-DPI multi-monitor = blurry text/chrome and hit-test drift. Single most likely "looks broken on Win11" defect. (win F2)
- **Affected ADW modules:** `WinShell`, `DlgShell`, and everything built on them (`TextWindows`, `Terminal`, `SplitterControl`, dialogs).
- **Modern replacement:** `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` + manifest `<dpiAwareness>PerMonitorV2`; handle `WM_DPICHANGED` (resize/reposition, reload fonts, recompute cell metrics/grains); `GetDpiForWindow` instead of one-shot DPI.
- **RECREATION RULE:** If/when M2WINRT recreates the GUI framework, declare PerMonitorV2 in the manifest AND actually re-derive font/cell/grain metrics on `WM_DPICHANGED` â€” the manifest line alone trades blur for clipped/oversized content. (Outside the stated P1â€“P5 module set; schedule with the UI rebuild.)

### H9. winmm `timeSetEvent` deprecated; global `timeBeginPeriod` discouraged â€” Gates **Phase 3-adjacent (Timers)**
- **Finding:** `Timers` is built entirely on winmm multimedia timers and raises the **global** system timer resolution; Windows 11 made timer-resolution requests per-process, so the global-period model is obsolete. Also a documented unguarded teardown race. (win F4)
- **Affected ADW modules:** `Timers`.
- **Modern replacement:** Thread-pool timers (`CreateThreadpoolTimer`/`SetThreadpoolTimer`, torn down with `WaitForThreadpoolTimerCallbacks`), or `CreateWaitableTimerExW(...CREATE_WAITABLE_TIMER_HIGH_RESOLUTION)` for sub-15ms. Drop `timeBeginPeriod`.
- **RECREATION RULE:** Recreate `Timers` on thread-pool / high-resolution waitable timers behind the unchanged `CreateTimer`/`DestroyTimer` interface; never call `timeBeginPeriod` globally. (Group with Phase 3 since it sits alongside the Threads/Win32-helper work; it depends on no other module.)

### H10. Dual ANSI/Unicode build + `CP_ACP`/`mbstowcs` conversions â€” Gates **Phase 2 (FormatString) and Phase 3 (FileFunc, Registry, Environment)**; cross-cuts P4/P5 string handling
- **Finding:** Library compiles A and W variants (`CHAR` 8- or 16-bit); 8â†”16-bit conversion uses `MultiByteToWideChar`/`WideCharToMultiByte` against **`CP_ACP`** (locale-dependent, lossy); ExStrings hand-rolls BMP-only UTF-16â†”UTF-8; Unix branch uses `mbstowcs`. The A build is a deprecated path in active use; mixing A-APIs on Win11 invites mojibake. (win F7)
- **Affected ADW modules:** `ExStrings`, `FileFunc`, `WinShell`, plus `TextWindows`/`Registry`/`ConfigSettings` byte-length math.
- **Modern replacement:** Unicode (W) APIs + UTF-16 internally; drop the ANSI build; explicit `CP_UTF8` (never `CP_ACP`, never `mbstowcs`) at any 8-bit boundary; manifest `<activeCodePage>UTF-8</activeCodePage>`.
- **RECREATION RULE:** M2WINRT ships **Unicode-only** (W APIs, UTF-16 internal canonical form) â€” do NOT recreate the dual A/W build split. Any 8-bit boundary uses `CP_UTF8`. Set the UTF-8 active-code-page manifest. Decide CHAR width once, in the Phase-2 string layer (FormatString) and Phase-3 file/registry helpers, so the rest of the library inherits it.

---

## ðŸŸ¡ MEDIUM â€” modernize

### M1. HMAC hard-wired to SHA-1 â€” **Phase 4**
- `HMAC`, `CryptKey` PBKDF2 PRF â†’ HMAC-SHA-256 (`BCRYPT_ALG_HANDLE_HMAC_FLAG`). **RULE:** expose `HMAC_SHA256`; never expose an HMAC bound to SHA-1 except as legacy-verify. Compare MACs in constant time (depends on Phase-1 MemUtils constant-time compare). (crypto F6)

### M2. Obsolete PBKDF1 / PBKDF2-SHA-1 with weak cost â€” **Phase 4**
- `CryptKey` â†’ Argon2id (preferred) or PBKDF2-HMAC-SHA-256 â‰¥ 600,000 iters via `BCryptDeriveKeyPBKDF2`. **RULE:** retire `KDF1` entirely; default `KDF2` to HMAC-SHA-256 with a tunable â‰¥600k floor and â‰¥16-byte CSPRNG salts; store algo/salt/params per credential and migrate on next successful auth; normalize password encoding to UTF-8. (crypto F7)

### M3. RSA OAEP/PSS bound to SHA-1, key sizes too small (768/1024) â€” **Phase 4**
- `RSA`, `CryptEncode` â†’ RSA-3072+ with OAEP/PSS-SHA-256/MGF1-SHA-256, or migrate to Ed25519/ECDSA-P256/X25519. **RULE:** `CryptEncode` is already hash-agnostic â€” pass SHA-256 + `hashLen=32`; require â‰¥3072-bit RSA; prefer generating keys via CNG/KSP; prefer ECC for new keys to retire the big-integer code. SHA-1 verify-only for old signatures. (crypto F8)

### M4. Nothing is constant-time (timing/cache side channels) â€” **Phase 4**, depends on **Phase 1 MemUtils**
- `AES` (T-tables), `VLI`/`RSA` (data-dependent exp, no blinding, short-circuit compares), `DES`/`Blowfish` (S-box lookups), `CryptEncode` (`DataBlocksEqual`/`UnpadBlock`). **RULE:** adopt CNG (constant-time + AES-NI/SHA-NI) wholesale; for any compare under our control use the Phase-1 constant-time compare on MACs/tags/padding. (crypto F10)

### M5. Prefer CNG over roll-your-own; never adopt legacy CAPI â€” **Phase 4 (overarching)**
- all of `crypto/` â†’ a thin internal CNG-backed crypto **faÃ§ade**; legacy modules kept behind it as decrypt/verify-only shims, deleted once data is re-protected. **RULE:** M2WINRT crypto is a CNG faÃ§ade by design. Never adopt legacy CryptoAPI (`advapi32` `Crypt*`). Enable CNG FIPS mode where compliance requires. (crypto F11)

### M6. Legacy DNS `gethostbyname` (IPv4-only, not thread-safe, first-addr-only) â€” **Phase 5**
- `Socket.GetHostAddr` â†’ `GetAddrInfoW`/`GetAddrInfoExW`, `InetPtonW`/`InetNtopW`, `AF_UNSPEC` connect-walk. **RULE:** Phase-5 socket resolves with `GetAddrInfoW`, dual-stack, iterating all candidates. (net F3)

### M7. Use WinHTTP, not WININET, for any HTTP â€” **Phase 5 (forward-looking)**
- Governs future HTTP + the Graph SMTP-replacement path â†’ WinHTTP (`winhttp.dll`, TLS 1.3 + HTTP/2). **RULE:** any HTTP in M2WINRT lands on WinHTTP; WININET is banned for service/background use. (net F4)

### M8. LDAP must require LDAPS/StartTLS + sign & seal â€” **Phase 5 (forward-looking, if used)**
- `winldap`/wldap32 binding â†’ `ldap_sslinit`/`ldap_start_tls_s`, `LDAP_OPT_SIGN`/`LDAP_OPT_ENCRYPT`. **RULE:** if M2WINRT exposes LDAP, default to LDAPS/StartTLS + signing/sealing, validate cert, fail closed; prefer Negotiate/Kerberos binds. (net F5)

### M9. Hand-rolled synchronization â†’ native OS primitives â€” **Phase 3 (Threads)**
- `Threads` (`CriticalSection`/PROTECT, `ConditionVariable`, `RwLock`, `Barrier`, `Hibernate`/`Awaken`, `SpinLock`); consumers `FileFunc`, `BitVectors`, `RandomNumbers`. â†’ `SRWLOCK`(+recursion shim) or native `CRITICAL_SECTION`, `CONDITION_VARIABLE`, `InitOnceExecuteOnce`, `WaitOnAddress`/`WakeByAddress*`, Thread Pool API. **RULE:** in Phase 3, re-base the `PROTECT` lock on SRWLOCK/CRITICAL_SECTION **preserving the contract exactly** (recursive, owner-tracked, non-owner-Leave raises) since FileFunc/BitVectors/RandomNumbers embed it as a `critic` field. RwLock loses recursion/fairness â€” flag the behavior delta to consumers. (win F5)

### M10. x87 FPU control word is legacy on x64 â€” **Phase 1/3-adjacent (Float)** â€” *not in the P1 module set, but note*
- `Float` â†’ SSE2/AVX + MXCSR (already the AMD64 path). **RULE:** standardize on SSE2/MXCSR; keep x87 only as the IA-32 legacy fallback; drop it entirely if 32-bit support is dropped. (Relevant to NewM2 codegen choices; SpecialReals itself carries none of this.) (win F6)

### M11. HKLM-by-default config â€” **Phase 3 (Registry/ConfigSettings)**
- `ConfigSettings`, `Registry` registration â†’ default HKCU; per-user `HKCU\Software\Classes`; MSIX + `Windows.Storage.ApplicationData` for packaged apps. **RULE:** Phase-3 config defaults to per-user; HKLM only on explicit, elevated request; provide a read-fallback during transition. (win F9; sec F10)

### M12. `FindFirstFile` + MAX_PATH long-path handling â€” **Phase 3 (FileFunc)**
- `FileFunc` â†’ `FindFirstFileEx`(`FindExInfoBasic` + `FIND_FIRST_EX_LARGE_FETCH`), manifest `<longPathAware>true`, widen `FileSpecString` beyond MAX_PATH, stop stripping `\\?\`, consider `CreateFile2`. **RULE:** Phase-3 FileFunc enumerates with `FindFirstFileEx` and is long-path-aware; do NOT strip the `\\?\` prefix (ADW actively removes it today). (win F10)

### M13. Integer-overflow / allocation-size math â€” **Phase 1 (MemUtils), Phase 4 (VLI/CryptKey)**, P3 launch buffers
- `Conversions`, `VLI`, `ExStorage`, `MemUtils`, `CryptKey` â†’ checked `count*element` / `a+b` before alloc; centralize `SafeMulSize`/`SafeAddSize`; validate sizes at trust boundaries; implement (not stub) portable `ZeroMem`/`MoveMem*`. **RULE:** provide checked size-arithmetic helpers in **Phase-1 MemUtils**; every allocation site that derives size from external length must use them; never ship a stubbed `ZeroMem`/`MoveMem`. (sec F7)

### M14. Latent COM resource leaks â€” **Phase 5 (COM)**
- `ActiveXControl` (four embedding interfaces never `Release`d), `OleException` (EXCEPINFO BSTRs never `SysFreeString`d), `CompoundFile` (`STATSTG.pwcsName` never `CoTaskMemFree`d). **RULE:** Phase-5 COM code releases every AddRef'd interface in FINALLY, frees every BSTR it receives, and `CoTaskMemFree`s task-allocated memory. (sec F8)

### M15. GDI/GDI+ rendering â†’ Direct2D/DirectWrite/WIC â€” **UI phase (outside P1â€“P5 core)**
- `WinShell`, `TextWindows`, `Terminal`, `SplitterControl` â†’ Direct2D (`ID2D1*`), DirectWrite (`IDWrite*`), WIC (`WinCodec`). **RULE:** if the GUI framework is recreated, add a Direct2D back-end behind the existing `Drawable`/`DrawContext` seam; migrate text first (biggest visual win). Large, optional; not gating P1â€“P5. (win F1)

---

## âšª LOW â€” hygiene / polish

- **L1. Socket lifecycle hygiene** â€” `Socket.Close` doesn't null the handle; no send timeout. â†’ null handle on close, add `SO_SNDTIMEO` + non-blocking connect/select deadline, request current Winsock version. **Phase 5.** (net F7)
- **L2. Win11 window aesthetics** (dark mode / Mica / rounded corners) â€” `WinShell`, `Terminal` â†’ `DwmSetWindowAttribute` (`DWMWA_USE_IMMERSIVE_DARK_MODE`, `DWMWA_SYSTEMBACKDROP_TYPE`, `DWMWA_WINDOW_CORNER_PREFERENCE`) + `SetWindowTheme` dark controls. **UI phase, optional.** (win F3)
- **L3. Console emulation â†’ ConPTY/VT** â€” `Terminal`, `TextWindows` â†’ `CreatePseudoConsole` for hosting; `ENABLE_VIRTUAL_TERMINAL_PROCESSING` for VT output. The GDI grid stays valid as an embedded widget. **UI phase, optional.** (win F8)
- **L4. CHM help & Simple MAPI are legacy** â€” `WinShell.DisplayHelp`/`HTMLHELP`, `SimpleMAPI` â†’ browser-based HTML help via `ShellExecute`; Microsoft Graph or `mailto:` for mail. (CHM is MotW/UNC-blocked.) **Phase 5 / UI, optional.** (win F11)
- **L5. Avoid admin / HKLM writes** â€” run as standard user, `requestedExecutionLevel=asInvoker`, per-user store; isolate genuine machine-wide ops behind a separate elevated helper. **Phase 3 / build.** (sec F10)
- **L6. Zeroize keys** (tracked under H4) â€” `SecureZeroMemory` on all crypto teardown even for modules slated for replacement, since they run during transition. **Phase 4.** (crypto F12)

---

## Cross-cutting quick wins (land before deep refactors)

1. Swap the security RNG to `BCryptGenRandom` and wall off the lagged-Fibonacci PRNG (C1) â€” highest impact.
2. Ship the hardened manifest + link flags + Authenticode signing (H5).
3. Harden DLL loading: `SetDefaultDllDirectories(SYSTEM32)` + `SetDllDirectory("")` at init; full-path the thunks (H2).
4. Replace `%COMSPEC% /C` with `CreateProcessW` (program+argv) (C3).
5. Tighten IPC objects: explicit DACL + `Local\` + `FILE_FLAG_FIRST_PIPE_INSTANCE` (H3).
6. Ban broken primitives at the API surface; default to AES-256-GCM + PBKDF2-HMAC-SHA256 â‰¥600k (H7, M2).
7. Zeroize secrets on teardown (H4) â€” needs the Phase-1 MemUtils SecureZero helper.
8. Add TLS to SMTP (C2/H6).

---

## Runtime caveat carried forward (gates H5's CFG/CET)

The ADW exception runtime (`SYSTEMEX`) does return-address rewriting and manual SEH that conflict with Control Flow Guard and Intel CET shadow stacks â€” ADW treats this as a dedicated porting workstream, not a flag flip. **For M2WINRT this is re-scoped to NewM2:** M2WINRT does not use the ADW toolchain, so before enabling `/guard:cf` / `/CETCOMPAT` you must verify what NewM2's own exception/codegen model does with return addresses and indirect calls. Do not assume ADW's SEH constraints â€” but do not assume they're absent either; audit NewM2's emitted exception machinery against CFG/CET before flipping those flags.

---

### Phase-gating summary table

| Phase | Modules | Gating items |
|---|---|---|
| **P1** | MemUtils, SpecialReals, SortLib, Money | **MemUtils:** SecureZero (H4/L6), working ZeroMem + checked size math (M13/F7), constant-time compare (M1/M4). **Money:** overflow/rounding correctness (financial, not security). **SpecialReals, SortLib:** none (pure compute). |
| **P2** | FormatString, RandomNumbers, TimeFunc | **C1** (CSPRNG split; RandomNumbers = non-crypto only). **H10** (Unicode-only, CP_UTF8) for FormatString. TimeFunc: none material. |
| **P3** | Environment, Registry, FileFunc, Threads | **C3** (no-shell launch), **H1** (handle inheritance), **H9** (Timers), **M9** (Threadsâ†’SRWLOCK), **M11** (HKCU), **M12** (FindFirstFileEx/long paths), **H10** (file/registry string width). |
| **P4** | crypto | **H4, H7aâ€“e, M1, M2, M3, M4, M5, L6** â€” all on the CNG faÃ§ade. Depends on C1 (RNG) and P1 MemUtils (SecureZero, constant-time compare, checked sizes). |
| **P5** | COM, network | **C2** (SMTP/TLS), **H3** (IPC DACLs), **H6** (Schannel socket), **H1** (PipedExec handles), **M6/M7/M8** (DNS/WinHTTP/LDAP), **M14** (COM leaks), **L1** (socket hygiene). |
| **Build/cross** | all | **H5** (mitigations/manifest/signing), **H2** (DLL search hardening at init). |
| **UI (outside P1â€“P5 core)** | WinShell/TextWindows/Terminal/etc. | **H8** (DPI), **M15** (Direct2D), **L2/L3/L4** (aesthetics/ConPTY/help). |

Source documents read in full: `e:/cleanroom/modernization/{README,cryptography,network-protocols,windows-apis,security-hardening}.md`.
