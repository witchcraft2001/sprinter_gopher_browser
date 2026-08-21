# CLAUDE.md — Gopher browser for Sprinter (port of nihirash's Moon Rabbit)

> Project guidance for AI agents and developers. Keep this file current as the
> project evolves.

## 1. What this project is

A **Gopher protocol browser for the Sprinter computer** (a Z80-based ZX Spectrum
clone), running under **DSS** in the native **80×32 text mode**. Displayed name is
just **"Gopher"** ("Gopher browser for Sprinter") — NOT "Moon Rabbit"; the home
page and docs credit the original it is based on (see below).

It is a port of the **Moon Rabbit / Internet NEXTplorer** lineage of Z80 gopher
browsers by *nihirash* — preserve that attribution in the home page, docs and
license headers.

Toolchain: **sjasmplus**, output is a **DSS `.EXE`** (assembly, not C).

### v0.2.0 — networking is a runtime-loaded UNET DLL (current architecture)

Both network cards are served by the same **UNET ABI**, a small (24-function)
Z80 calling convention frozen and shared by two DLLs:

- **`UNETESP.DLL`** — ESP12-F/ESP8266 Wi-Fi (ESP-AT), from `extern/wifi`
  (submodule of `sprinter_net`, Roman Boykov / Dmitry Mikhalchenkov).
- **`UNETRTL.DLL`** — NE2000/RTL8019AS ISA Ethernet, from `extern/rtl`
  (submodule of `sprinter-rtl8019a`).

The browser itself never talks to either card directly (no ESP-AT commands, no
ISA register pokes): it loads the right DLL at **runtime**, via
**libman** (`extern/libman`, a Sprinter dynamic-library loader/manager), and
drives it through `src/net.asm`'s `NET.*` facade. Which DLL to load is chosen
by the environment variable **`NET`** (`WIFI` → `UNETESP.DLL`, `RTL` →
`UNETRTL.DLL`), exactly like the sibling projects `sources/weather-forecast`
and `sources/ftpclient`. There is a **single build** — no more `BACKEND_ESP`/
`BACKEND_NE2000` compile-time switch, no statically-linked ESP-AT kit code,
and (as a deliberate consequence) **no more support for ESP-AT 2.2.1
specifically** — the DLL owns firmware-version differences internally.

`extern/wifi`, `extern/rtl` and `extern/libman` are **git submodules**, pinned
to specific commits and verified by `make deps` (`tools/check_deps.py`) before
every build — see §5 and §7.

## 2. Status

**v0.2.0 shipped: full migration from a statically-linked ESP-AT kit to the
runtime UNET-DLL architecture described above.** `make` / `make deploy` /
`make dist` all build and package cleanly (0 errors). On-target regression
(MAME ESP + real hardware for both backends) is the next step — see the
verification checklist in the migration plan history below if you need the
exact test matrix; day-to-day, just: build, deploy, run the usual browsing/
download/bookmark/search flows over Wi-Fi, and separately smoke-test RTL in
MAME (`NETCFG -i; IFUP` per `extern/rtl`'s docs).

Everything from menu parsing, the paged document buffer, history/back-cache,
downloads, bookmarks, config file, and the appended-home-page loader-EXE trick
(§4a) predates this migration and is unchanged in behavior — only the
networking transport underneath `src/net.asm` changed. See `git log` for the
detailed history of both the original ESP-AT-kit implementation (v0.1.x) and
the v0.2.0 UNET-DLL migration if you need archaeology; this file only
describes the current architecture.

## 3. Sprinter platform architecture (essentials)

**CPU:** Z84C15 (CMOS Z80), 7 MHz normal / 21 MHz turbo. Fully Z80 instruction
compatible.

**Memory model — four 16 KB windows** mapped by write-only port registers:

| Z80 range     | Window | Port | Notes |
|---------------|--------|------|-------|
| `0000–3FFF`   | WIN0   | `#82` | BIOS ROM (RST #08/#10) — not ours |
| `4000–7FFF`   | WIN1   | `#A2` | **app code loads here** |
| `8000–BFFF`   | WIN2   | `#C2` | runtime scratch + stack (GetMem page, see §4a) |
| `C000–FFFF`   | WIN3   | `#E2` | doc pages / libman loader scratch (time-shared) |

`OUT (port), page` instantly remaps that window. 4 MB+ RAM in 16 KB pages.

**DSS (operating system).** API via `RST #10`, function number in `C`,
params in `A/B/D/E/H/L/IX/IY`. Return: `CF=0` ok, `CF=1` error (code in `A`).
- **Critical:** do **not** use `EXX` / `EX AF,AF'` around DSS/BIOS calls — the
  alternate register set is reserved by DSS.
- **Critical:** the **stack must live in WIN2** (`8000–BFFF`) when calling
  DSS/BIOS — they may remap WIN1 and WIN3.
- **`SETWIN #38` is broken for WIN1 on current Estex-DSS** (can silently map
  the wrong page while still returning CF=0) — libman itself avoids it and
  uses the explicit `SETWIN1/2/3` (`#39/#3A/#3B`) calls instead; keep the same
  rule if you ever write low-level window-mapping code elsewhere.

**BIOS.** API via `RST #08` (function in `C`); mouse via `RST #30`. Provides
low-level disk/memory/video; e.g. `#8A` `LP_SCROLL_UD` for hardware scroll
(DSS `#55 Scroll` is known to wedge on full-width regions — use BIOS `#8A`).

**80×32 text mode.**
- **DSS launches apps already in 80×32 text mode (`#03`) — no `SetVMod` needed**
  at startup; `INIT_VMODE` (`src/util_local.asm`) just records the mode so
  `EXIT` can restore whatever the app was in before it ran (rare: only matters
  if something else already switched modes before launching us).
- Print: DSS `PChars #5C` (ASCIIZ, `HL=string`), `PutChar #5B`, `WrChar #58`.
- Cursor: `Locate #52`. Region ops: `Clear #56`, `Scroll #55` (full-width →
  use BIOS `#8A` instead). Attribute byte = `INK[3:0] | PAPER[7:4]`, 16 colours
  each. Charset is CP866 (Cyrillic in `0x80–0xFF` is directly printable).
- Direct text VRAM (fast path, used for download progress): VRAM page `#50`
  into WIN3, `PORT_Y #89` selects column; each row entry is
  `(mode, sym, attr, modex)` at `#C300+row*4`. Park `PORT_Y=#C0` afterwards.

**Keyboard.** DSS `WaitKey #30` (blocking), `ScanKey #31` (non-blocking; returns
raw key codes, not ASCII — map nav keys by code; a Ctrl+letter combo has no
symbolic code (A/E=0) and must be read from the physical keycode — see
`console.inc`'s `KEY_B/KEY_D/KEY_G` and `main.asm`'s Ctrl-combo dispatch).

**Files.** DSS `Open #11` / `Close #12` / `Read #13` / `Write #14` / `Create #0A`
/ `Delete #0E` / `MoveFP #15` (seek). Dir: `MkDir/RmDir/ChDir/CurDir`,
`F_First #19` / `F_Next #1A`. FAT16 on IDE, 8.3 names.

**Memory alloc.** DSS `GetMem #3D` (B=pages → A=block), `SetWin #38`/`SetWin1/2/3`
(map block page into a window), `FreeMem #3E`.

**Environment variables.** DSS `Environ #46` (`B=ENV_GET/ENV_SET`), page-scoped,
persist across program runs in a session; names auto-uppercased. Used for the
`NET` backend-selection variable (§5) — the browser only *reads* it; it is
published by `NETUP` (Wi-Fi) or `NETCFG -i` (RTL), run beforehand by the user.

> ⚠️ **Source of truth for DSS/BIOS numbers:** the values above are for
> orientation. When writing code, use the **proven equates** in
> `src/include/dss.inc`/`sprinter.inc` (this project's own, not the network
> kits' — see §7's include-path note) and cross-check against
> `Estex-DSS/DSS/API/*.asm` if something is missing.

## 4. WIN3 discipline (doc pages / libman loader scratch)

WIN3 hosts, at different times, never both at once:
- A mapped **document page** (`OUT (PAGE3=#E2), phys`, `phys` resolved once at
  `GetMem` time via BIOS `EMM_FN5 #C5` — see §4a).
- **libman's loader scratch** during `l_load`/`l_free` (a temporary 2-page
  `GetMem` block it allocates and maps itself, restoring the caller's prior
  WIN3 page before returning) — this only happens inside `NET.INIT`'s first
  call (loading the DLL) and inside `NET.SHUTDOWN` (freeing it), never during
  an ordinary `NET.CONNECT/SEND/RECV/CLOSE` (those are plain `l_call`s, which
  map WIN1 — not WIN3 — for the DLL itself; see §5).

Rules: never call DSS/BIOS while a doc page is mapped in WIN3 without copying
the needed bytes out first (`LINE_BUF` in WIN2). Never call `NET.INIT`/
`NET.SHUTDOWN` while a doc page's raw pointer is "in flight" (i.e. always
finish reading/copying out of a mapped page before touching the network layer)
— in practice this already falls out naturally since fetch/download code paths
don't hold a raw WIN3 pointer across a `NET.*` call.

## 4a. Memory budget & layout (current, v0.2.0)

Z80 sees four 16 KB windows. WIN1 holds the whole program image (code + small
state); WIN2 is one `GetMem`'d 16 KB page, mapped once at startup and never
touched again, holding runtime scratch buffers, the runtime stack, **and
libman itself**; WIN3 is doc pages (time-shared with libman's loader scratch,
§4).

**WIN1 (code).** Loads at `0x4100` (512-byte header before it, at `0x3F00`).
The EXE header's `LOADER` field = `IMAGE_END - LOAD_ADDR`, making `GOPHER.EXE`
a *loader EXE*: DSS loads exactly that many bytes and leaves the file **open**
(handle at `(IX-3)`, captured into `home_fm` as `START`'s first instruction),
so the program can seek past the image and read what's appended in the file
tail. Two special blocks sit at the end of the file:
1. **`LIBMAN_STORE`** — libman (`extern/libman/libman/libman.asm`, core +
   state, default build understanding L0/L1/L2 DLL formats) assembled via a
   sjasmplus `DISP LIBMAN_W2_BASE ... ENT` block, so its *code* is written as
   if it already ran at `LIBMAN_W2_BASE` while its *bytes* are emitted at the
   end of the WIN1 image, **just before the `IMAGE_END` label** — i.e. inside
   the `LOADER`-covered image, so DSS auto-loads them into WIN1 like any other
   code. `START` then `LDIR`s them from `LIBMAN_STORE` (their WIN1 address) to
   `LIBMAN_W2_BASE` (their intended WIN2 address) right after mapping the WIN2
   page. No file I/O needed for this — unlike the home page below. (Placement
   before `IMAGE_END` is load-bearing: bytes after it would not be loaded by
   DSS at all, and `HOME_OFFSET` would point into them.)
2. **`INDEX.GPH`** (the home page) — appended by the Makefile *after* the
   loader-EXE tail cutoff (`HOME_OFFSET = 0x200 + IMAGE_END - LOAD_ADDR`), read
   at startup via the still-open `home_fm` handle (`LOAD_HOME_FILE`), **not**
   loaded into memory by DSS. This lets the home page be edited
   (`data/index.gph`) without touching WIN1 layout at all.

> ⚠️ **No byte emission before the header's `ORG`.** Everything included above
> `ORG LOAD_ADDR - 0x0200` in `main.asm` (`macro.inc`, `dss.inc`, …) must be
> pure EQUs/MACROs: a stray `DB` there is emitted at address 0 and sjasmplus
> `--raw` prepends those bytes to the output file, shifting the whole EXE
> header (DSS then rejects the file). This is why `MACRO_LINE_END` lives in
> `util_local.asm`, not `macro.inc`.

**WIN2 (runtime page, `console.inc` is the map).** Mapped once by
`INIT_RUNTIME_PAGE` (`GetMem` B=1 + `SetWin2`). Holds, low to high: `STAGE`
(file/DLL-search streaming buffer), small fixed buffers (bookmark builder,
history records, config accumulator, path/exec buffers, the current page's
host/port/selector, `LINE_BUF`), a 4 KB `DL_BUF` (the generic network receive
buffer — every `NET.RECV` call targets it, whether for a page fetch or a
binary download), then:
```
LIBMAN_W2_BASE EQU 0xB000   ; libman (LDIR'd here from LIBMAN_STORE at startup)
LIBMAN_W2_END  EQU 0xB900   ; 2304 B budget (measured ~2092 B; ASSERT in main.asm)
RUN_STACK_TOP  EQU 0xC000   ; runtime stack, 0xB900..0xC000 = 1792 B, grows down
```
Why libman has to be WIN2-resident even though the *DLL itself* loads into
WIN1: `l_call`/`l_load` map the DLL/loader into whichever window the caller
requested (WIN1 here — see §5) and **restore the previously-resident physical
page there before returning** (verified directly in
`extern/libman/libman/libman_core13.asm`: self-modifying code stores the old
page and `OUT`s it back just before `ret`). That means WIN1 — all of gopher's
own code — is displaced only for the narrow span *inside* one `l_call`/
`l_load`; nothing outside libman's own runtime code (`libman_state.inc`,
which must stay mapped for the whole call) can be executing from WIN1 during
that span. Since gopher's `NET.*` facade calls happen *from* WIN1 code, the
thing directly wrapping `l_call` (`net.asm`'s `CALL_UNET`) is safe to stay in
WIN1 — the CALL/RET pair around `l_call` only needs WIN1 to be valid **before**
the call and **after** it returns, both of which libman guarantees. Only
libman's own dispatcher code needs to live somewhere that is never the DLL's
target window, hence WIN2.

Why the stack shrank from the historical 4 KB to 1792 B: the old ESP-AT kit
had deep, IDLE_CB-drawing-heavy call chains inside its own AT-command/receive
byte-waits; none of that exists anymore (`NET.RECV` is a single flat `l_call`,
and the browser's own receive loops are plain polls with no callback
re-entrancy). The UNET ABI documents "≥256 B free stack" as its own
requirement; 1792 B is a comfortable margin. If future DLL versions need more,
widen `RUN_STACK_TOP - LIBMAN_W2_END` there's still ~6 KB of freed WIN1 space
(post-migration `IMAGE_END` is roughly 6 KB below the old, kit-inclusive image)
before anything gets tight again.

**Documents (no 16 KB limit).** Unchanged from before the migration: a gopher
document is a chain of `GetMem` 16 KB blocks (list of block-ids + total length
+ line count), capped at 16 pages = 256 KB (truncated beyond that, not a
crash). `EMM_FN5 #C5` resolves each block's physical page once at alloc time;
`MAP_PAGE` is then a single `OUT (PAGE3=#E2), phys`. See `src/doc.asm`.

## 5. Network HAL — UNET ABI via libman

`src/net.asm` (`MODULE NET`) is a thin facade over the UNET ABI
(`extern/wifi/src/include/unet.inc`, byte-identical in `extern/rtl` and
verified so by `make deps`). Read `unet.inc` itself for the authoritative
function numbers/register contracts/error codes/capability bits — it is
short, thoroughly commented, and the single source of truth. Summary:

- **Calling convention:** `HL=handle` (cached in `net.asm`'s `dll_handle`),
  `B=function number`, arguments **only** in `A`/`DE`/`IX`/`IY` (never
  `HL`/`BC` — those are consumed by the libman dispatcher), via
  `LIBMAN.l_call`. Status comes back in `A` (`0`=`NERR_OK`, else `NERR_*`);
  **test `A`, not `CF`** — libman's own `CF` only ever signals a *dispatch*
  failure (bad handle/window), never a UNET-level error. `net.asm`'s
  `CALL_UNET` helper wraps this (`EI` guard before entering the DLL — mirrors
  a fix from `sources/ftpclient`'s `ede8c46`: a call entered with interrupts
  off can hang inside a DLL's own tick-based waits — then `l_call`, mapping
  dispatch failure to a local `NERR_DLL_CALL`, and latching `net_cancelled`
  whenever the DLL itself reports `NERR_CANCEL`).
- **Window:** the DLL is loaded into **window 1** (`l_load A=1`) — see §4a for
  why libman itself must then be WIN2-resident, not WIN1.
- **`NET.INIT`** (cached by `main.asm`'s `net_inited` flag, same pattern as
  before the migration): first call reads env `NET`, `l_load`s the matching
  DLL, checks `GETCAPS`' ABI major byte and caches its capability bitmask,
  `SETOPT`s `CANCELKEYS=1` (so the DLL polls Esc/Ctrl+Z during its own
  blocking waits), probes `STATUS(0xFF)` (env-only, no hardware). Every call
  (cached DLL or not) then does a best-effort `NETDONE` followed by `NETINIT`
  — this is what makes `INVALIDATE_NET` (clears only `net_inited`, not the
  DLL-loaded flag) a cheap, correct way to recover a stale session (idle time
  on a local page, or a child program via `Dss.Exec` having touched the card)
  without a full DLL reload.
- **`NET.CONNECT/SEND/RECV/CLOSE`**: thin register-shuffling wrappers around
  `UNET_FN_CONNECT/SEND/RECV/CLOSE` (channel 0 always — gopher never needs
  `UNET_CAP_MULTICHAN`). `NET.RECV` is length-framed with a reliable
  `NERR_CLOSED` (any trailing bytes on close are delivered in the same call,
  never dropped) — this is the ABI's main win over the old ESP-AT `+IPD`
  scanning: no drain-gate/accumulator/tail-protection machinery is needed
  anywhere in `main.asm` anymore. Both `RECV_LOOP` (page fetch,
  `src/main.asm`) and `DL_RECV_LOOP` (binary download) are now plain polls: 1
  second per `NET.RECV` call, append whatever arrived, `CLOCK_TICK` +
  count consecutive idle polls (~15 s budget) if nothing did, stop on
  `NERR_CLOSED`.
- **`NET.RX_PAUSE`/`RX_RESUME`** (fn 13/14) are gated on `UNET_CAP_RXFLOW` in
  the cached caps bitmask and are a no-op otherwise; the only remaining call
  site is `DL_MIDFLUSH` (pausing across a mid-download FAT write on backends
  that need explicit flow control, resuming once the write completes).
- **`NET.SHUTDOWN`** (`main.asm`'s `QUIT`, only if `net_inited` was ever set):
  `NETDONE` + `l_free` the DLL, so the next program (or the next run of this
  one) starts clean.
- **`NET.CHECK_NET_UP`**: env-only (`NET`=`WIFI`/`RTL`), no DLL/hardware touch
  — cheap enough to call on every home-page status-bar redraw.
- **`NET.LAST_ERROR`** (fn 16) fills a 128-byte `NET_ERRBUF` with the DLL's own
  diagnostic tail; available for richer error messages but not yet wired into
  every status-bar error path (a reasonable follow-up, not required for
  correctness).
- **`NET.DIAG_TEXT` + `init_stage`/`init_code`** — a bring-up failure is
  otherwise a single opaque "init failed" covering seven distinct causes, so
  `NET.INIT` records *which* stage failed (`IST_*` in `net.asm`) with its
  result code, and `DIAG_TEXT` appends that plus libman's own breadcrumbs to
  the status line (`main.asm`'s `INIT_ERR_TEXT`, built into `WEBLINK_BUF`):
  ```
  Net init failed - run NETUP/NETCFG. st=2 e=32 lr=1 ls=3 dss=3 is=0
  ```
  `st` = `IST_ENV`(1)/`LOAD`(2)/`GETCAPS`(3)/`ABI`(4)/`CAPS`(5)/`STATUS`(6)/
  `NETINIT`(7); `e` = the accompanying code (a `NERR_*` for `st=7`, the ABI
  major byte for `st=4`, the caps low byte for `st=5`); `lr`/`ls`/`dss`/`is`
  are `LIBMAN.l_reason` (1=OPEN i.e. file not found, 2=LOAD i.e. bad format,
  3=WINDOW), `l_load_stage` (`LS_*`: 1 temp-alloc, 2 temp-map, 3 open, 4 I/O,
  5 format, 6 copy, 7 target, 8 DLL-INIT, 9 cleanup), `l_dss_error` and
  `l_init_status` — all meaningful only for `st=2`. Read `st` first: it says
  whether the DLL was even found (2), whether it is the wrong build (3/4/5),
  or whether the card/link is down (7).

**Config contract with the user:** the browser reads `NET` and nothing else —
Wi-Fi join / RTL bring-up is entirely the DLL + `NETUP`/`NETCFG -i`+`IFUP`'s
job, run once beforehand. There is no `NET.CFG` parsing in this codebase.

## 6. Build

```sh
git submodule update --init          # first checkout only
make deps                            # verify submodule pins + DLL checksums
make                                  # -> build/GOPHER.EXE
make deploy                          # -> distr/gopher.img (DSS floppy, GOPHER.EXE + both DLLs)
make dist                            # -> distr/gopher.zip (EXE + both DLLs + cfg + home page + readmes)
```

`tools/check_deps.py` (run automatically by `make`/`make deploy`/`make dist`
via the `deps` target) pins each submodule's remote URL + commit hash, and
each shipped DLL's exact size + SHA-256, plus byte-comparing `unet.inc`
between `extern/wifi` and `extern/rtl`. A stale `git submodule update` or a
locally-edited DLL fails the build loudly instead of silently shipping the
wrong thing. **Bumping a submodule pin is deliberate**: update the commit in
`tools/check_deps.py` (and the DLL size/hash if it changed) in the same change
that runs `git -C extern/<kit> checkout <new-commit>`.

**Include-path precedence — non-obvious sjasmplus behavior:** `sjasmplus`
searches `-I` directories in **reverse** of the order given on the command
line (the *last* `-I` is searched *first*). The Makefile's `INCDIRS` lists the
extern kit dirs first and `src/include`/`src/lib` **last** specifically so a
same-named local file (e.g. `macro.inc`, which this project vendors its own
trimmed copy of instead of the kit's) always shadows the kit's copy. If you
add another `-I`, keep this ordering in mind — getting it backwards produces
confusing "Label not found" errors deep inside a *different* file than the one
you edited, because a same-named include silently won instead of erroring.

`sjasmplus --raw` emits the `.EXE` body; `LOADER`/`STACK_TOP`/`APP_VERSION`
are the app-specific EQUs (`src/main.asm`, `src/include/app_version.inc`).
`BUILD_DATETIME` is auto-stamped into `build/buildinfo.inc` on every build and
shown in the load/exit banner (`MSG_BANNER`).

## 7. Conventions & gotchas

- **No `EXX`/`EX AF,AF'`** around DSS/BIOS; stack in WIN2 for those calls.
- **`SETWIN #38` is broken for WIN1** on current Estex-DSS — use the explicit
  `SETWIN1/2/3` calls (libman already does; keep the same rule elsewhere).
- **`ScanKey` returns raw codes**, not ASCII — keep a key map (`console.inc`).
- **Cyrillic = CP866**; gopher content is usually UTF-8 → a UTF-8↔CP866 recode
  for content is a known future improvement (see `SpecTalkZX/sprinter/src/recode.c`
  for the table approach), not yet implemented.
- **This project's own `src/include/dss.inc`/`sprinter.inc`/`macro.inc` are
  authoritative** — do not assume a network-kit include of the same name
  defines the same thing; the include-path ordering in §6 is what keeps this
  project's copies in effect even though the kits are on the search path too.
- NEXTplorer/Moon Rabbit ship under *Nihirash's Coffeeware License* — preserve
  attribution and license headers from base files.
- **`MAINLOOP` dispatch is `JP`-based** (`JP Z, ON_x`), so a key handler runs
  with an empty stack (`SP = RUN_STACK_TOP`). A handler MUST end by
  `JP MAINLOOP` — it must NOT tail-jump into a routine that ends in `RET`
  (e.g. `JP SET_STATUS`, which RETs via `TERM.PUTS`): that `RET` pops garbage
  above the WIN2 page and hangs. Use `CALL SET_STATUS` + `JP MAINLOOP`. A bare
  `JP SET_STATUS` is only OK as a tail-call inside a routine that was itself
  `CALL`ed (e.g. `SHOW_ERROR`, `SHOW_DOC_STATUS`).
- **`net_inited` (main.asm) vs `NET.dll_loaded` (net.asm) are different
  flags** — `net_inited` gates whether `DO_FETCH`/`DOWNLOAD` call `NET.INIT`
  at all (cleared by `INVALIDATE_NET` to force a cheap NETDONE+NETINIT
  recovery); `NET.dll_loaded` gates whether the DLL itself needs `l_load`ing
  (cleared only by `NET.SHUTDOWN`, i.e. program exit). Don't conflate them.
- **CF is the error contract — clear it explicitly on success paths.** `CP n`
  sets CF whenever `A < n`, so a comparison used only for branching still
  leaks its borrow into the caller's `RET C`/`JR C`. End a "CF=0 ok / CF=1
  error" routine's success path with an explicit `OR A` (preserves `A`, clears
  CF) instead of whatever flags the last instruction happened to leave. This
  shipped as a real bug in `net.asm`'s `CALL_UNET` (`CP NERR_CANCEL` set CF for
  every status below 8, `NERR_OK` included), making **every** successful DLL
  call look like a dispatch failure; the on-target symptom was the impossible
  `st=3 e=0` — "GETCAPS failed, with status success". Two structural reviews
  missed it: the code reads correctly, only its flag effects are wrong.

## 8. Reference index (local paths)

- **This project's submodules** (pinned, see `.gitmodules` + `tools/check_deps.py`):
  - `extern/wifi` — ESP-AT/Wi-Fi kit + `UNETESP.DLL` (upstream `sprinter_net`)
  - `extern/rtl` — NE2000/RTL8019A kit + `UNETRTL.DLL` (upstream `sprinter-rtl8019a`)
  - `extern/libman` — the DLL loader/manager (upstream `sprinter-libman`)
- **Sibling projects using the same UNET-DLL-via-libman pattern** (read these
  first for any networking question — they are the working reference
  implementations this project's `net.asm` was modeled on):
  - `/Users/dmitry/dev/zx/sprinter/sources/weather-forecast` — closest analog
    for a Gopher-style single-shot fetch loop (`transport.asm`'s
    `GOPHER_FETCH`); `weatherc.asm` for the INIT/backend-select sequence.
  - `/Users/dmitry/dev/zx/sprinter/sources/ftpclient` — closest analog for a
    long-lived interactive session (`net.asm`); has the `EI`-before-`l_call`
    guard and the RX_PAUSE/RX_RESUME register-preservation fix this project's
    `net.asm` also carries; uses a different window split (`LIBMAN_WIN0`,
    DLL→WIN2) because its own code occupies WIN0+WIN1 — **not** directly
    applicable to this project's WIN1-code/WIN2-scratch layout, see §4a.
- **libman docs:** `extern/libman/libman/README.md` (ASM-level API — this is
  the one to read, **not** the top-level `extern/libman/README.md`, which
  documents the unrelated `sprinter-mkdll` Python DLL-packaging tool).
- **Platform manual:** `/Users/dmitry/dev/zx/sprinter/sprinter_ai_doc/manual`
  (`01_architecture`, `02_memory`, `03_bios`, `04_dss`, `05_graphics`, `08_peripherals`)
- **DSS source:** `/Users/dmitry/dev/zx/sprinter/Estex-DSS/DSS`
- **BIOS includes:** `/Users/dmitry/dev/zx/sprinter/sprinter_bios/Shared_Includes/constants`
- **Emulator:** MAME Sprinter; `extern/rtl`'s docs cover its `NETCFG -i; IFUP`
  MAME bring-up flow for RTL testing (no real hardware needed for that path).

Worked example apps (idiomatic sjasmplus DSS programs — copy patterns for EXE
header, video/text mode, mouse, file dialogs, build/floppy packaging; none of
these use the UNET/libman pattern, they predate it):
- `/Users/dmitry/dev/zx/sprinter/sources/tasm_071/TASM`
- `/Users/dmitry/dev/zx/sprinter/sources/fformat/src/fformat_v113`
- `/Users/dmitry/dev/zx/sprinter/sources/fm/FM-SRC/FM`
- `/Users/dmitry/dev/zx/sprinter/texteditor` (has its own `CLAUDE.md`)
- `/Users/dmitry/dev/zx/sprinter/utils`

## 9. Known follow-ups (not blocking, not yet done)

- `data/esp/howto.md`/`howto_ru.md` (bundled as `readme.txt`/`readmeru.txt`)
  still describe the old ESP-AT-kit setup story; rewrite for the DLL/`NET` env
  var world (mention `NETCFG -i`/`IFUP` for RTL too).
- `NET.LAST_ERROR`'s text (the DLL's own last AT/driver response) is still not
  appended to `ERR_CONN`/`ERR_SEND`. `ERR_INIT` now carries the structured
  `NET.DIAG_TEXT` breadcrumbs instead (see §5), which is what a bring-up
  failure actually needs; `LAST_ERROR` would add backend-specific detail.
- On-target regression across both backends (§2) — MAME + real hardware for
  ESP, MAME for RTL (real RTL hardware is a nice-to-have, not required).
- UTF-8 → CP866 recode for gopher content (never implemented; pre-existing
  gap, unrelated to this migration).
- Cursor does not yet skip non-selectable (`i`/`.`) rows on Up/Down in menus
  (pre-existing gap).
- "Back to previous page" gopher links (common on nihirash-style servers)
  still push a new history level and re-fetch instead of acting like
  Backspace (pre-existing gap; see old TODO notes in `git log` for the
  detection approach considered).
