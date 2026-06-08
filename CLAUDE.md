# CLAUDE.md — Gopher browser for Sprinter (port of nihirash's Moon Rabbit)

> Project guidance for AI agents and developers. Keep this file current as the
> port progresses. See `plan.md` for the staged porting plan.

## 1. What this project is

A **Gopher protocol browser for the Sprinter computer** (a Z80-based ZX Spectrum
clone), running under **DSS** in the native **80×32 text mode**. Displayed name is
just **"Gopher"** ("Gopher browser for Sprinter") — NOT "Moon Rabbit"; the home
page and docs credit the original it is based on (see below).

It is a port of the **Moon Rabbit / Internet NEXTplorer** lineage of Z80 gopher
browsers by *nihirash* — preserve that attribution in the home page, docs and
license headers (do not present "Moon Rabbit" as this port's own name). We take
the most recent **pure‑Z80** core (`internet-nextplorer`) as the base, and adopt
the cleaner architecture ideas from the newest `agon-snail` (transport/fetcher
split, `file://` transport).

Networking reuses the existing Sprinter network kits behind a thin, compile-time
switched HAL:

- **Default backend — ESP Wi-Fi** (`SprinterESP`, ESP12-F/ESP8266, ESP-AT firmware)
  via `sprinter_wifi/network`.
- **Alternate backend — NE2000 / RTL8019AS ISA Ethernet** via `sprinter-rtl8019a`.

Both kits are authored by the user (Dmitry Mikhalchenkov) on top of Roman
Boykov's SprinterESP, expose a similar `TCP.*` socket-like API, and share a
common `NET.CFG`. The browser must build for **either** card via one `-D` switch.

Toolchain: **sjasmplus**, output is a **DSS `.EXE`**. (Decision: assembly, not C.)

### Locked decisions (from project kickoff)
- **Base core:** `internet-nextplorer` (Z80) + new ideas from `agon-snail`.
- **Language:** Z80 assembly, `sjasmplus`.
- **Network:** reuse `sprinter_wifi` (ESP, default) + `sprinter-rtl8019a` (NE2000)
  behind a `NET.*` HAL chosen at build time; shared `NET.CFG`.
- **Display:** DSS native 80×32 text mode (video mode `#03`).
- **No proxy server.** NEXTplorer needs a proxy because the Next UART lacks flow
  control; Sprinter's TL16C550 UART has RTS/CTS hardware flow control
  (`WCOMMON.SETUP_UART_FLOW`), so the proxy driver is dropped entirely.

## 2. Status

**Phase 0 (toolchain & skeleton) — done & verified on target (MAME, BIOS v3.06).**
- `make` (sjasmplus, 0 errors) → `build/GOPHER.EXE` (DSS EXE, 128-byte header,
  loads `0x8100`, SP `0xBFFF`). `make deploy` → `distr/gopher.img` (bootable DSS
  floppy, `/GOPHER/GOPHER.EXE`). `tools/run.sh` launches MAME.
- DSS launches already in 80×32; no `SetVMod` needed.

**Phase 1 (platform HAL + static menu) — done, awaiting on-target check.**
- `src/term.asm` (MODULE TERM): `CLS`, `FILL` (DSS Clear #56 — also sets the
  colour for following prints), `LOCATE` (#52), `PUTS` (#5C), `PUTC` (#5B).
- `src/kbd.asm` (MODULE KBD): `SCAN` (non-blocking #31; A=char, D=positional,
  Z=no key). Key codes in `console.inc`: arrows Up `#58`/Down `#52`/Left
  `#54`/Right `#56` (positional, in D); Enter `#0D`/Esc `#1B` (in A).
- `src/main.asm`: header bar + 30-row viewport (rows 1..30, no gap under header)
  + status bar, rendering a static 34-entry gopher menu (type-byte + ASCIIZ
  records). **Incremental rendering** (no full redraw per keypress): an in-page
  move only recolours the two affected rows via BIOS `Lp_Print_Atr #83` (text
  untouched); an edge step scrolls the viewport with DSS `Scroll #55` and draws
  only the newly exposed row; page jumps do a full `RENDER_VIEWPORT`. Enter
  echoes the target on the status line, Esc exits.
- `src/include/console.inc`: DSS console fn numbers, **BIOS fn numbers**
  (`#83 Lp_Print_Atr`, `#84 Lp_Set_Place`, `#8A Lp_Scroll_Up`, called via
  `RST #08`), attribute bytes (PAPER hi-nibble | INK lo-nibble), key codes.
- BIOS text calls go through `RST #08` directly (texteditor does the same); stack
  stays in WIN2, no `EXX`. `Lp_Print_Atr`: B=cell count, E=attr at cursor.
- **Scroll: use DSS `Scroll #55` (`RST #10`), not raw BIOS `Lp_Scroll_Up #8A`.**
  `#55`: D=top-row, E=col, H=height, L=width, B=1 up/2 down, A=0. Raw `#8A` uses
  WIN2 as scratch and corrupts a WIN2-resident app (the texteditor only survives
  it by relocating its stack and swapping the WIN2 page in `CallBios`); `#55` is
  WIN2-safe by design. (Supersedes the earlier "#55 wedges, use #8A" note.)
- `file.asm` (DSS file API / `file://`) deferred to Phase 3 when it's first needed.

**Phase 2 (ESP network backend + real fetch) — done, awaiting on-target check.**
- `src/net.asm` (MODULE NET, `IFDEF BACKEND_ESP`): `INIT` (ISA reset, UART find,
  `REQUIRE_NET_UP`, NETCFG load/baud, UART init, AT/ATE0, `SETUP_UART_FLOW`,
  CIPMUX=0), `CONNECT`→`TCP.OPEN`, `SEND`→`TCP.SEND_BUFFER`, `RECV`→`TCP.RECEIVE`,
  `CLOSE`→`TCP.CLOSE`. Wraps the network-kit libs.
- **Memory model changed for networking:** app now loads at `0x4100` (512-byte
  header), stack `0x8000` (grows down through the WIN1 code page); a 16 KB
  receive buffer `GOPHER_BUF` lives in a `GetMem`'d WIN2 page mapped with
  `SetWin2` at startup (`INIT_RUNTIME_PAGE`). Lib BSS high-water ~`0x66xx`.
- Enter now fetches `gopher.floodgap.com:70` root into `GOPHER_BUF` and dumps it
  (filtered) to the console, then returns to the menu. (Phase 3 will parse the
  buffer into menu entries and render it instead of dumping.)
- **Build:** Makefile adds `-I $(NETKIT)/src/{include,lib}` (NETKIT =
  `sprinter_wifi/network`). Include order matters: `netcfg_lib` **before**
  `wcommon` (defines `_NETCFG`, which gates `SETUP_UART_FLOW`); `esplib` **last**
  (its `RS_BUFF` anchors the lib BSS chain into post-image RAM). `wcommon`
  requires the app to define `DEFAULT_TIMEOUT` globally.
- **Run/test:** `tools/run_esp.sh` (ESP ISA card + bitb socket bridge + network
  kit floppy as B:). Requires `NETUP` to have joined Wi-Fi first; needs the
  user's ESP bridge for real internet. `tools/run.sh` (no ESP) still runs the
  menu UI but Enter will report a network error.

**Phase 3 (gopher engine — end-to-end browsing) — first on-target test done;
re-test pending.** First MAME run rendered garbage: the **first doc page was never
allocated** (empty-doc `APPEND` saw "0x4000 free" and skipped `.new_page`, so
`MAP_PAGE` OUT'd `doc_phys[0]=0` → physical page 0 into WIN3). Fixed: `APPEND`
now forces `.new_page` when `doc_npages==0`. Also added incremental nav + ESP
shutdown-on-exit (below). Awaiting a re-test.
- `src/doc.asm` (MODULE DOC): paged document buffer per §4a. Raw fetched bytes
  live in a chain of up to 16 GetMem 16 KB pages (cap 256 KB → `doc_trunc`, no
  crash). ISA window and one doc page **time-share WIN3**. Mapping a doc page is
  the fast path the user requested and it **works on MAME/real HW**: DSS GetMem
  (#3D) gives a block HANDLE; at alloc time BIOS **`EMM_FN5` (#C5)** (`A=handle,
  HL=dest → writes the block's physical page bytes, #FF-terminated`) resolves it
  into `doc_phys[]`; `MAP_PAGE` then maps via a single **`OUT (PAGE3=#E2), phys`**.
  `RD_BYTE` re-OUTs every byte (the OUT is cheap), so a DSS/BIOS print that
  clobbers WIN3 between bytes is harmless. (There is NO transparent CPU cache
  issue — the Sprinter "cache" is opt-in SRAM in WIN0 only; my earlier
  cache/SetWin3 reasoning was wrong. `EMM_FN4 #C4` is dead RTL `pagemem.asm`
  code; we use `#C5`.) Position tracked as (page,offset) pairs (no 24-bit math).
  `RESET`, `APPEND` (STAGE→pages, maps WIN3 + `LDIR`), page-aware reader
  (`SEEK_LINE`/`NEXT_LINE`/`RD_BYTE`/`AT_END`/`PREV_LINE`), `COUNT_LINES`.
  **`SEEK_LINE` is RELATIVE, not from-start.** It steps from a one-entry cache
  (`sc_line`+page+offset) — forward via `SKIP_LINE`, backward via `PREV_LINE`
  (page-aware backward byte scan) — never re-scanning from line 0. Consecutive
  seeks to nearby lines (the nav pattern) are O(1); this fixed the
  slower-and-slower / hang on held arrows and the cursor "vanishing" on far
  pages (both were the old O(n)-per-keypress from-start scan). `COUNT_LINES`
  still does one scan at load to set `doc_lines` (total — for a future
  position/progress indicator) — that's the only full scan, amortised by fetch.
  **`AT_END` preserves HL/DE** — `NEXT_LINE` keeps its `LINE_BUF` write pointer in
  HL across the `AT_END` call; the original `AT_END` clobbered HL, so every copied
  byte went to a junk address and `LINE_BUF` stayed empty (this — NOT the memory
  syscalls — was the long-standing "garbage/blank rows" bug).
- `LINE_BUF` lives in **WIN1** (the code image, `MAIN.LINE_BUF`), not the WIN2
  scratch page: DSS PChars prints the row's display field straight from it.
  (STAGE/REQ_BUF/HIST_DATA stay in the WIN2 GetMem page — they're plain memory,
  never a PChars source.) Each visible line is copied into `LINE_BUF` **before**
  any TERM/DSS call.
- `src/main.asm` rewritten: gopher rows parsed (`PARSE_ROW`: type/display/
  selector/host/port, TABs→NUL) and rendered straight from doc pages through the
  30-row viewport. **Menu vs text documents:** `DOC_TYPE_CUR` holds the gopher
  type of the current doc. Type `1` = menu (parse type byte + TAB fields, icon +
  display at col 2, links selectable). Type `0` = **plain text** — the line is raw
  text with NO type byte/fields, so `PARSE_ROW`/`DRAW_ROW` print the WHOLE line
  from col 1 (was stripping the first char as a "type"), all rows normal attr,
  Enter does nothing. **Navigation:** an in-page Up/Down recolours only the two
  changed rows via BIOS `Set_Place`+`Print_Atr` (`RECOLOR_ROW`; `sel_type` cached
  for de-highlight). An Up/Down **at a viewport edge** hardware-scrolls one line:
  **BIOS `Lp_Scroll_Up #8A` with DI/EI** (`B`=dir, `D`=begin-line, `E`=line-count,
  per BIOS docs + texteditor/SpecTalkZX), then draws the one new row. **Use #8A,
  NOT DSS `Scroll #55`** — #55 hung the browser on long pages; the proven apps all
  use #8A with interrupts OFF (that was the missing piece). PgUp/PgDn full-redraw
  via `RENDER_VIEWPORT` (cheap, O(1) SEEK) and are **blocked when the selection
  can't move** (at top/end). Keys (positional, in D): PgUp `#59`, PgDn `#53`;
  Left/Right also page. **Header** shows the current page title (`DOC_TITLE` = the
  clicked link's display text; saved/restored in history `HR_TITLE`).
  Enter follows `0`/`1` links (NET connect/send/recv into a fresh doc); other
  types report "not supported yet". Backspace = back. Built-in **home** menu
  (`WELCOME_DOC`, gopher-format with real links) loaded at startup with no
  network, so the UI is usable before the first fetch.
- **On exit** (`QUIT`): if the ESP was ever initialised (`net_inited`), call
  `NET.SHUTDOWN` (AT+CIPCLOSE + ATE0) to hand the card back in AT command mode so
  the next program isn't blocked. We use CIPMODE=0 throughout (kit's +IPD path),
  so no transparent-mode `+++` escape is needed (unlike SpecTalkZX's `esp_restore`).
- **History:** stack of nav records `{kind,host,port,selector,type,sel,top}` in
  the WIN2 page (`HIST_DATA`), cap 16, oldest dropped on overflow. **Back
  re-fetches** the parent (network) or reloads home — a deliberate v1
  simplification of §4a's "no-refetch keep-the-page-chain" model (only ONE doc
  chain is alive at a time → far less memory/complexity; upgrade later).
- **Memory model — model A (proven wget layout), NOT the flat §4a image.** All
  code + small state + stack (top `0x8000`, down) live in WIN1; the big scratch
  buffers (`STAGE`/`LINE_BUF`/`REQ_BUF`/`HIST_DATA`, addresses in `console.inc`)
  live in a single GetMem page mapped at WIN2 (`0x8000`) via `INIT_RUNTIME_PAGE`.
  `SetWin2` is safe **because no code lives in WIN2** (the §4a fear was code in
  WIN2). Doc pages use WIN3 only (`OUT (#E2)` of a `EMM_FN5`-resolved page).
- **Network errors** classified to friendly status-bar messages (init/connect/
  send/empty); no program exit, no blocking "press a key". `NET.INIT` now calls
  a CF-returning `CHECK_NET_UP` instead of `WCOMMON.REQUIRE_NET_UP` (which exits).
  **Bring-up sped up:** `NET.INIT` runs once (`net_inited` flag) and is reused
  for every subsequent `TCP.OPEN`, so only the first fetch pays the ~30 s cost.
- **Link stability (mirrors the kit's wget) — fixed flaky "init/Send failed".**
  `NET.INIT` no longer calls `ISA.ISA_RESET` (it reset the card and broke the ESP
  session NETUP set up — the main cause); it drains stale UART bytes
  (`UART_EMPTY_RS`) and recovers a stalled first AT (`ESP_RESET`+re-init, retry).
  `NET.CONNECT` preps the socket (RX-resume, `TCP.CLOSE` stale, drain) and
  **retries `TCP.OPEN` once** after a settle. `NET.SEND` uses
  `TCP.SEND_BUFFER_NO_WAIT`. **RTS/CTS flow control during the transfer:**
  `RECV_LOOP` raises RTS (`NET.RX_RESUME` → `UART_RX_PAUSE/RESUME`, TL16C550 AFE)
  before each `TCP.RECEIVE` and **drops it during the slow append/redraw**, so the
  ESP holds its TX and the UART FIFO never overruns. `SETUP_UART_FLOW` (ESP side)
  is set in `INIT`.
- **Download progress** on the status bar: `SHOW_PROGRESS` shows the running
  downloaded size ("Loading N bytes" < 1 KB, else "Loading N KB"; `UTIL.UTOA`
  for the decimal). Gopher has no content-length, so it's amount, not a percent.
  `doc_lines` (total, from `COUNT_LINES`) is available for a future scroll
  position indicator.

## TODO (Phase 3 polish / Phase 4) — agreed on-target

**High value / requested:**
1. **Doc caching for instant Back — DONE.** Each history record carries a 40-byte
   copy of the DOC descriptor (`HR_DOCSTATE`: block-ids + phys pages + metadata);
   follow = `PUSH_HIST` (`DOC.SAVE_STATE`) + `DOC.NEW` (detach, don't free); Back =
   `DOC.RESET` (free current) + `POP_HIST` (`DOC.LOAD_STATE`, restores the cached
   pages, no re-fetch); overflow frees the oldest level's pages (`DOC.FREE_STATE`).
   Cap 8 levels; pages stay GetMem-allocated while cached.
2. **Unsupported gopher item types** (currently "not supported yet"): type `7`
   **search — DONE** (`INPUT_LINE` status-row prompt → `SEL_CUR = selector + TAB +
   query`, fetched and rendered as a type-1 menu). **Binary downloads — DONE**
   (types `9`/`5`/`g`/`I`/`s`/`;`/`d`/`p` via `IS_BIN_TYPE`): `DOWNLOAD` streams the
   selector straight to a file in `DOWNLOAD\` (`src/file.asm` = DSS Create `#0A`/
   Write `#14`/Close `#12`/MkDir `#1B`; backslash 8.3 paths) **without touching the
   current document or history** (dedicated `DL_HOST/DL_PORT/DL_SEL` buffers).
   Filename derived from the selector basename, sanitised to 8.3 (`MAKE_DLNAME` +
   `SANITIZE_CH`, fallback `INDEX.BIN`); status shows running/final size ("Saving/
   Saved N KB to DOWNLOAD\NAME"); Esc cancels (kit `CANCELLED`); disk-full → ERR_DISK.
   `DL_RECV_LOOP` mirrors `RECV_LOOP`'s RTS flow-control bracketing, `FILE.WRITE`
   from `STAGE` (WIN2) after `NET.RX_PAUSE` closes ISA. Still TODO: `h` (URL/`URL:`
   links); the **confirm-to-open-externally** step below.
   **Media policy (agreed):** binary/media items are **saved to a `DOWNLOAD\`
   directory** (next to the EXE) via the DSS file API (`file.asm`) — DONE; the
   browser does NOT auto-open them. Opening is **on explicit confirmation only**,
   and via an **external program** (e.g. `Dss.Exec` the right viewer/player) —
   never inline. So: download (done) → confirm prompt → optionally launch external
   app (TODO).
2b. **Download dir is next to the EXE — DONE.** `INIT_PATHS` (in START) does the
   **`ChdirExeHome`** idiom (from `package-hub/pkglib/home_dir.asm`): DSS
   **`AppInfo #47, B=1`** with the **buffer in HL** (the API does `EX DE,HL` —
   passing it in DE writes to a junk address and the first attempt did exactly
   that → downloads landed in the launch cwd, e.g. `C:\DOWNLOAD\`), returning the
   EXE's home dir (incl. trailing `\`), then **`DSS_CHDIR`** into it. So the cwd
   becomes the EXE's dir and the relative `DOWNLOAD\` paths land beside
   `GOPHER.EXE`. Best-effort: if `AppInfo`/`CHDIR` is unavailable (older DSS) we
   stay in the current dir. (`AppInfo B=2` = full path+name — reserved for the
   appended-home-page reader, item 6a. Buffer size: `APPINFO_BUF_SIZE`=256.)
2a. **Config file (`GOPHER.CFG` next to the EXE) for downloads/viewers.** A small
   text config, parsed at startup, that holds:
   - **download directory path** — overrides the `<exedir>DOWNLOAD\` default (so the
     user can point it at e.g. a different drive/folder); create it if missing.
   - **type/extension → program map** — which DSS program opens which file type,
     used by the confirm-to-open-externally step (item 2). E.g. lines like
     `tap=TRDEMU.EXE`, `scr=VIEWER.EXE`, `gif=GIFVIEW.EXE`, plus optional defaults
     by gopher item type (`I`, `s`, `;`, `9`). On confirm, look up the downloaded
     file's extension (or item type), `Dss.Exec` the mapped program with the path.
   Format: simple `key=value` per line, `#`/`;` comments, ASCIIZ; reuse the
   NET.CFG-style parser idea. Falls back to built-in defaults (`DOWNLOAD\`, no
   viewers) if the file is missing or a key is absent.
3. **Cancel during the network phase — DONE.** Esc (also Ctrl+Z) cancels both
   Fetching and Loading: the kit polls `WCOMMON.CHECK_CANCEL_IN_ISA` inside its
   UART/TCP/RECEIVE byte-waits and sets `WCOMMON.CANCELLED`; we clear it at fetch
   start, abort retries (`AT_RECOVER`/`CONNECT`) on cancel, and `FETCH_ERR` shows
   "Cancelled". (Note: cancel during `WIFI.UART_FIND` at the very start of INIT is
   not polled by the kit, so the first ~moment isn't cancellable — minor.)
4. **Clock in the status bar** (DSS `SYSTIME #21`), refreshed in the main loop.
5. **Ctrl+S** — save the current document to a file (DSS file API).
6. **Ctrl+D** — add the current document (host/port/selector + title) to bookmarks.
6a. **Externalise the home page out of the code image** (frees ~1.2 KB; keeps the
   home page editable). **Chosen mechanism: append it to the EXE at build time and
   read it back at startup** (the loader idiom of fn/kode/tasm/spevosdk). Plan:
   - **Build (Makefile):** after sjasmplus emits `GOPHER.EXE`, append the home-page
     gopher text, then an 8-byte self-describing trailer `["GPH1"][len:dword]`.
     A plain `--raw` EXE declares its load size in the header, so DSS loads only
     the code image and IGNORES the appended bytes (they stay on disk).
   - **Runtime:** `AppInfo #47 B=2` → the EXE's full path; `DSS_OPEN` it read-only;
     `MOVE_FP SEEK_END` → size; seek `size-8`, read the trailer; verify `GPH1`;
     seek `size-8-len`, read `len` bytes (loop into `STAGE` → `DOC.APPEND`) as the
     home doc; `DSS_CLOSE`. Falls back to a tiny built-in `WELCOME_DOC` stub if the
     open/trailer fails. (Alternative considered: a loader-style EXE keeping the
     file open via `EXE_FM` at `(IX-3)` — rejected as riskier; reopen-by-path is
     simpler and needs no EXE-header surgery. A separate `index.gph` companion file
     is the other option but the user wants a single bundled EXE.)
   NEEDS on-target verification that DSS ignores the appended bytes for a `--raw`
   EXE and that `AppInfo` works on the target BIOS (item 2b validates AppInfo).
6b. **Bookmarks file** next to the EXE (e.g. `bookmarks.gph`), opened by **Ctrl+B**
   (or a link on the home page); Ctrl+D appends to it.
6c. **Ctrl+G — open an arbitrary address**: a text-input prompt (host[:port][/sel])
   then fetch it.
7. **Empty doc after long Fetching** on a flaky fetch — investigate / harden
   (treat tiny/whitespace-only results as an error; better timeout classify).
   PARTIALLY DONE: the status bar now shows the loaded size and flags
   "- INCOMPLETE" when the gopher "." terminator was never received
   (`doc_complete`, `SHOW_LOADED`). Still want to auto-retry / resume truncated
   transfers (likely a `RECV_TIMEOUT` / kit early-stop issue on slow servers).

12. **Startup network detection — DONE.** At launch (and on the home page) the
   status bar shows "Wi-Fi not up - run NETUP first" when `NET.CHECK_NET_UP` (fast
   env check, no UART) fails, so the user knows before clicking a link instead of
   waiting through a failed `NET.INIT`. Mirrors SpecTalkZX `net_init` NET_NO_LINK.
13. **Confirm on exit — DONE.** Esc at the menu now prompts "Quit Moon Rabbit? Y =
   yes, any other key = no" (`CONFIRM_QUIT`); only Y/y quits. (Esc still cancels a
   running fetch/download directly - that path doesn't reach the menu loop.)

**Lower priority:**
8. Cursor skips non-selectable (`i`/`.`) rows on Up/Down in menus.
9. `file://`/`home://` via a fetcher/transport router (agon-snail idea); on a
   net error offer **re-init ESP** (NETRESET/NETUP via `Dss.Exec`).
10. UTF-8 → CP866 recode for content (gopher servers vary).
11. Phase 4: NE2000 backend behind the same `NET.*` HAL.
14. **Long menu lines are truncated** (gopher display strings often exceed 80
   cols). This is our renderer: `CLIP_DISP` caps the display field at `SCR_W-4`
   (76 chars, a deliberate right margin that avoids the cursor-wrap-scroll bug),
   one row per item, no wrap/horizontal-scroll - same as NEXTplorer. Enhancement:
   horizontal-scroll the selected row, or wrap long lines onto continuation rows.

Reference repos are cloned at `/tmp/gopher-analysis/{moon-rabbit-zx,internet-nextplorer,agon-snail}`
(re-clone if gone). Working dir: `/Users/dmitry/dev/zx/sprinter/sources/moonrabbit`.

## 3. Sprinter platform architecture (essentials)

**CPU:** Z84C15 (CMOS Z80), 7 MHz normal / 21 MHz turbo. Fully Z80 instruction
compatible — *no eZ80 instructions* (so `agon-snail` code is reference-only).

**Memory model — four 16 KB windows** mapped by write-only port registers:

| Z80 range     | Window | Port | Notes |
|---------------|--------|------|-------|
| `0000–3FFF`   | WIN0   | `#82` | |
| `4000–7FFF`   | WIN1   | `#A2` | |
| `8000–BFFF`   | WIN2   | `#C2` | **app loads here**, stack here |
| `C000–FFFF`   | WIN3   | `#E2` | VRAM / extra RAM / **ISA window** |

`OUT (port), page` instantly remaps that window. 4 MB+ RAM in 16 KB pages.

**DSS (operating system).** API via `RST #10`, function number in `C`,
params in `A/B/D/E/H/L/IX/IY`. Return: `CF=0` ok, `CF=1` error (code in `A`).
- **Critical:** do **not** use `EXX` / `EX AF,AF'` around DSS/BIOS calls — the
  alternate register set is reserved by DSS.
- **Critical:** the **stack must live in WIN2** (`8000–BFFF`) when calling
  DSS/BIOS — they may remap WIN1 and WIN3.

**BIOS.** API via `RST #08` (function in `C`); mouse via `RST #30`. Provides
low-level disk/memory/video; e.g. `#8A` `LP_SCROLL_UD` for hardware scroll
(DSS `#55 Scroll` is known to wedge on full-width regions — prefer BIOS `#8A`).

**EXE format.** 512-byte header, code loads at `0x8100`, `SP=0xBFFF`, command
line passed in `IX` (`IX = load-0x80 = 0x8080`: byte 0 = length, then ASCIIZ).
Exit with DSS `Exit #41` (never `RET`/`JP 0`). The header is emitted by the
network kits' `macro.inc`.

**80×32 text mode.**
- **DSS launches apps already in 80×32 text mode (`#03`) — no `SetVMod` needed.**
  Only call `SetVMod #50` (`A=#03`; 40×32 is `#02`) if the app itself switched to
  another mode and wants to return; in that case save the old mode with
  `GetVMod #51` and restore it on exit.
- Print: DSS `PChars #5C` (ASCIIZ, `HL=string`), `PutChar #5B`, `WrChar #58`.
- Cursor: `Locate #52` (note 1-based in some wrappers — verify against `dss.inc`).
- Region ops: `Clear #56`, `Scroll #55` (full-width → use BIOS `#8A` instead).
- Attribute byte = `INK[3:0] | PAPER[7:4]`, 16 colours each. Charset is CP866
  (box-drawing glyphs available; Cyrillic in `0x80–0xFF` is directly printable).
- Direct VRAM (fast path, optional): VRAM page `#50` into WIN3, `PORT_Y #89`
  selects column, 4 bytes per cell `(mode, sym, attr, modex)` at `#C300+row*4`.

**Keyboard.** DSS `WaitKey #30` (blocking), `ScanKey #31` (non-blocking; returns
raw key codes, not ASCII — map nav keys by code). Use non-blocking in the main loop.

**Files.** DSS `Open #11` / `Close #12` / `Read #13` / `Write #14` / `Create #0A`
/ `Delete #0E` / `MoveFP #15` (seek). Dir: `MkDir/RmDir/ChDir/CurDir`,
`F_First #19` / `F_Next #1A`. FAT16 on IDE, 8.3 names.

**Memory alloc.** DSS `GetMem #3D` (B=pages → A=block), `SetWin #38` (map block
page into a window), `FreeMem #3E`. Use for page buffers larger than the 64 KB map.

> ⚠️ **Source of truth for DSS/BIOS numbers:** the values above are for
> orientation. When writing code, use the **proven equates** in
> `…/sprinter_wifi/network/src/include/dss.inc`, `sprinter.inc`, `macro.inc`
> (and the RTL kit's equivalents). Don't hand-transcribe syscall numbers — these
> headers already build working `.EXE`s.

## 4. ISA / WIN3 discipline (most important runtime rule)

The network card (ESP UART **or** NE2000) is on the **ISA bus mapped into WIN3**
(`C000–FFFF`). The kits manage this with `ISA.ISA_RESET` / `ISA.ISA_OPEN` /
`ISA.ISA_CLOSE`. Rules:
- Open the ISA window **only for short register/data bursts**, then close it.
- **Never call DSS/BIOS while the ISA window is open** (they touch WIN3).
- Keep code, data, and stack in WIN1/WIN2 so swapping WIN3 is safe.
- ESP UART is the TL16C550 at memory-mapped `0xC3E8` (when ISA open). RTL8019A
  registers are at its ISA base (e.g. `0xC300` for I/O base `0x300`).

## 4a. Memory budget & layout (IMPORTANT — agreed Phase 2)

Z80 sees four 16 KB windows; the ISA network card is fixed at **WIN3**. ISA and a
document page never need to be mapped at the same instant, so they **time-share
WIN3**. That frees WIN1+WIN2 entirely for program code/data/stack.

| Window | Role | Rule |
|--------|------|------|
| WIN0 `0000–3FFF` | BIOS ROM (RST #08/#10) | not ours |
| **WIN1+WIN2** `4000–BFFF` | **all code (low) + data + stack (`0xBFFF`, down)** | one flat load image; **never `SetWin2`** |
| **WIN3** `C000–FFFF` | **ISA window OR one document page** (never both) | transient; map ISA for fetch bursts, map a doc page for copy-in/render |

**Flat WIN1+WIN2 load.** Code at `0x4100` (512-byte header at `0x3F00`) growing
up; data + stack high in WIN2, stack `0xBFFF`. The image **must cross `0x8000`**
or DSS won't map the WIN2 page (pad/place data there to ensure it does). DSS maps
both pages from the image itself. **Never `Dss.GetMem`+`SetWin2`** — it would swap
a blank page over the code already loaded in WIN2 (SpecTalkZX PLATFORM.md). DSS
does not disturb WIN1/WIN2 during API calls; stack in WIN2 is correct for DSS/BIOS.

**Documents (no 16 KB limit).** A gopher document is a **chain of GetMem 1-page
(16 KB) blocks** — a list of block-ids + total length + line count. Pages are
allocated on demand as the document grows, capped at a **fixed 16 pages = 256 KB
per doc** (beyond that the document is truncated with a marker, not a crash).
  Map a doc page into WIN3 with **`OUT (PAGE3=#E2), phys`**, where `phys` was
  resolved once at alloc time via BIOS `EMM_FN5 #C5` from the GetMem handle (this
  is the loader/CD-driver idiom, works on MAME/real HW). No transparent-cache
  concern — the Sprinter "cache" is opt-in SRAM in WIN0 only.
- **Fetch:** `TCP.RECEIVE` into a small `STAGE` buffer (~2 KB, in WIN1/WIN2) while
  ISA is mapped in WIN3; then map the current doc page (`OUT PAGE3`) and copy
  `STAGE` into it, allocating a new page when it fills. (ISA and doc page take
  turns in WIN3.)
- **Read/render:** to read byte at offset O → page `O>>14`, `OUT (PAGE3),phys[page]`,
  read `0xC000 + (O & 0x3FFF)`; lines may cross pages. Copy each visible line into
  a line buffer (WIN1/WIN2), then TERM-print from it. **No DSS/BIOS call while a
  doc page is mapped in WIN3** (copy the line out first). Line finding is by
  forward scan (NEXTplorer style), page-aware.

**History.** Stack of document descriptors `{page block-id list, total_len,
line_count, host, port, selector, cursor, top}`. **Cap 8 levels**; on overflow or
GetMem failure, free the oldest level's pages (`FreeMem`). Back/forward restore a
descriptor and its view — *no re-fetch* (the link is slow). Cheap on 4 MB RAM.

**Discipline.** Never `SetWin2`. WIN3 holds ISA *or* one doc page, never persistent
data; never call DSS/BIOS while ISA or a doc page is mapped in WIN3. Only hold a
doc pointer within one mapped page; re-map for the next page. Track all block-ids
for `FreeMem`. Keep the flat image crossing `0x8000`.

## 5. Network HAL & the two backends

Define one internal interface; pick a backend with a single `-D` at build time.

```
NET.INIT      ; detect card, load NET.CFG, bring link up.  CF=1 = no/failed HW
NET.CONNECT   ; HL=host ASCIIZ, DE=port ASCIIZ -> open TCP. CF=1 = fail
NET.SEND      ; HL=buffer, BC=len  (send all)
NET.RECV      ; HL=buffer, BC=max, DE=timeout(ms) -> BC=bytes (0=none)
NET.CLOSE
NET.STATUS    ; link/connection state
```

**ESP backend (`BACKEND_ESP`, default).** Maps almost 1:1 onto the kit:
`ISA.ISA_RESET` → `WIFI.UART_FIND` → `NETCFG.LOAD` + `NETCFG.APPLY_UART_BAUD` →
`WIFI.UART_INIT` → `WCOMMON.SETUP_UART_FLOW` → then `TCP.OPEN` (hostname OK, ESP
resolves DNS), `TCP.SEND_BUFFER`/`SEND_BUFFER_NO_WAIT`, `TCP.RECEIVE`,
`TCP.CLOSE`, with `WIFI.UART_RX_PAUSE/RESUME` around processing.
Include from `…/sprinter_wifi/network/src/lib/`: `isa.asm`, `esplib.asm`,
`esp_tcp.asm`, `netcfg_lib.asm`, `wcommon.asm`, `util.asm`.

**NE2000 backend (`BACKEND_NE2000`).** Lower level: `RESOLVE.HOST` (host→IP) →
`RESOLVE.NEXT_HOP_FOR` (IP→gateway/MAC) → set `TCP_REMOTE_IP/MAC/PORT` →
`TCP.OPEN` → `TCP.SEND` / `TCP.RECV` / `TCP.CLOSE` (used by that kit's working
`WGET`). Include from `…/sprinter-rtl8019a/src/lib/`: `isa.asm`, `rtl8019.asm`,
`resolve_lib.asm`, `dns_lib.asm`, `tcp_lib.asm`, `arp_lib.asm`, `netcfg_lib.asm`,
`netenv_lib.asm`, `util.asm` (gate with the kit's `USE_*` DEFINEs).
The HAL's `NET.CONNECT` hides the resolve-then-open dance behind the same
`HL=host, DE=port` signature as ESP.

**Config:** both read `NET.CFG` (keys: `SSID/PASS/DHCP/IP/GATEWAY/NETMASK/`
`DNS1/DNS2/TZ/NTP/AUTOJOIN/BAUD`; NE2000 adds `RTL_IOBASE/RTL_IRQ/RTL_MAC`).
Wi-Fi join is done once by `NETUP.EXE`; the browser only opens TCP.

## 6. Base-core reuse map (internet-nextplorer → Sprinter)

Cloned base modules and their fate:

| NEXTplorer module | Fate in Sprinter port |
|---|---|
| `engine/fetcher.asm`, `engine/engine.asm` | **Keep** — rewire net calls to `NET.*` |
| `engine/history/*`, `engine/urlencoder.asm` | **Keep** (multilevel history, URL enc) |
| `engine/media-processor.asm`, `downloader.asm` | **Keep**, file I/O → DSS |
| `render/gopher-page.asm`, `row.asm`, `plaintext.asm`, `dialogbox.asm`, `ui.asm`, `buffer.asm` | **Adapt** — emit DSS 80×32 text instead of Next tiles |
| `drivers/tile-driver.asm`, `font.asm`, `next.asm` | **Replace** with DSS text driver |
| `drivers/keyboard.asm`, `input.asm`, `joystick.asm` | **Replace** with DSS `ScanKey` |
| `drivers/uart.asm`, `wifi.asm`, **`proxy.asm`** | **Replace** with `NET.*` HAL; **drop proxy** |
| `drivers/esxdos.asm` | **Replace** with DSS file API |
| `player/*` (Vortex), `screen-viewer/*` | **Defer** (optional later: AY music / images) |
| `main.asm` (`SAVENEX`, `nextreg`, IM via `ORG #38`) | **Rewrite** as DSS EXE entry |

From `agon-snail`, borrow the transport router idea: a `fetcher` that dispatches
on scheme (`network` vs `file://` vs `home://`) so local browsing and the
built-in home page share one path with network fetches.

## 7. Build

Pattern mirrors the network kits:
```
sjasmplus --nologo --fullpath \
  -I src/include -I src/lib \
  -DBACKEND_ESP \            # or -DBACKEND_NE2000
  --lst=build/GOPHER.lst --raw=build/GOPHER.EXE src/main.asm
```
`--raw` emits the DSS `.EXE`. Vendor (copy or symlink) the needed lib modules
from the two network kits under `src/lib/` so the browser is self-contained, or
add `-I` paths to the kits. A `Makefile` should build both backends and package a
FAT12 test image (see kits' `tools/build.sh`, `image.sh`).

## 8. Conventions & gotchas

- **No eZ80** — `agon-snail` is design reference only; never copy its opcodes.
- **No `EXX`/`EX AF,AF'`** around DSS/BIOS; stack in WIN2 for those calls.
- **ISA window open = no DSS/BIOS calls**; keep bursts short, always `ISA_CLOSE`.
- **Drop the proxy**; rely on TL16C550 RTS/CTS flow control.
- **DSS `Scroll #55` wedges full-width** → use BIOS `#8A LP_SCROLL_UD`.
- **`ScanKey` returns raw codes**, not ASCII — keep a key map.
- **Cyrillic = CP866**; gopher content is usually UTF-8 → add UTF-8↔CP866 recode
  if needed (see `SpecTalkZX/sprinter/src/recode.c` for the table approach).
- The kits' `dss.inc`/`macro.inc`/`sprinter.inc` are the **authoritative** equates.
- NEXTplorer/Moon Rabbit ship under *Nihirash's Coffeeware License* — preserve
  attribution and license headers from base files.

## 9. Reference index (local paths)

- **Base core (clone):** `/tmp/gopher-analysis/internet-nextplorer`
  (also `moon-rabbit-zx`, `agon-snail`)
- **ESP net kit:** `/Users/dmitry/dev/zx/sprinter/sprinter_wifi/network`
  (libs in `src/lib/`, `WGET`/`WTERM` apps are the best client examples)
- **NE2000 net kit:** `/Users/dmitry/dev/zx/sprinter/sprinter-rtl8019a`
  (libs in `src/lib/`, `WGET` app shows resolve→open→send→recv)
- **C reference port (ESP, IRC):** `/Users/dmitry/dev/zx/sprinter/sources/SpecTalkZX`
  (`sprinter/` — net/term/recode patterns, plan.md template)
- **Platform manual:** `/Users/dmitry/dev/zx/sprinter/sprinter_ai_doc/manual`
  (`01_architecture`, `02_memory`, `03_bios`, `04_dss`, `05_graphics`, `08_peripherals`)
- **DSS source:** `/Users/dmitry/dev/zx/sprinter/Estex-DSS/DSS`
- **BIOS includes:** `/Users/dmitry/dev/zx/sprinter/sprinter_bios/Shared_Includes/constants`

### Architecture & syscall references (read these for how-to)

Primary docs / OS sources (authoritative for architecture and the DSS/BIOS API):
- `/Users/dmitry/dev/zx/sprinter/sprinter_bios` — BIOS sources & shared includes
  (syscall equates, structures, EXE header, ATA/FS constants).
- `/Users/dmitry/dev/zx/sprinter/Estex-DSS` — full DSS OS source: `DSS/API/*.asm`
  enumerates every syscall, `DSS_MAP.TXT`/`Structures.inc`/`defines.inc` give the
  call numbers, register conventions and struct layouts.
- `/Users/dmitry/dev/zx/sprinter/sprinter_ai_doc/manual` — structured manual
  (architecture, memory, BIOS, DSS, graphics, peripherals).

Worked example apps (idiomatic sjasmplus DSS programs — copy patterns for EXE
header, video/text mode, mouse, file dialogs, ISA, build/floppy packaging):
- `/Users/dmitry/dev/zx/sprinter/sources/tasm_071/TASM` — TASM assembler IDE:
  large app with `Shared_Includes`, `MemMap.inc`, menu bar, dialog windows,
  depack — good reference for app structure and memory map.
- `/Users/dmitry/dev/zx/sprinter/sources/fformat/src/fformat_v113` — floppy
  formatter: ESTEX/DSS calls, mouse, GUI widgets (button/dialog/listbox/radio).
- `/Users/dmitry/dev/zx/sprinter/sources/fm/FM-SRC/FM` — file manager: file/dir
  syscalls, overlay modules, floppy-image build scripts.
- `/Users/dmitry/dev/zx/sprinter/texteditor` — text editor: `bios_equ.asm`,
  `dss_equ.asm`, `sp_equ.asm`, file dialog, menu — compact, well-commented
  reference for text mode + DSS file I/O (has its own `CLAUDE.md`).
- `/Users/dmitry/dev/zx/sprinter/utils` — small DSS utilities (deltree, diff,
  xcopy, make) with a `references/` dir — minimal examples and build harness.

SDKs / toolchains:
- `/Users/dmitry/dev/zx/sprinter/sdcc-sprinter-sdk` — SDCC Sprinter SDK
  (`include`, `lib`, `examples`, `docs`) — C-side reference for DSS bindings even
  though this port is assembly; useful for cross-checking syscall semantics.
