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
- `LINE_BUF` lives in **WIN2** at `0x9D80`; each visible
  line is copied into it **before** any TERM/DSS call (so no doc page stays
  mapped in WIN3 across the print). **MYTH BUSTED:** an earlier note here claimed
  "DSS PChars renders garbage from a WIN2 source string, so LINE_BUF must be in
  WIN1." That is **false** — verified on target: `PChars #5C` (which routes the
  string read through BIOS `LP_PR_LINE_DIR` via `RST ToBIOS`) prints **correctly
  from a WIN2 GetMem page** (`SHOW_EXEC_BANNER` PChars's the command line straight
  out of `CFG_CMD_BUF` at `0x9BA0`). The original "garbage rows" bug was the
  `AT_END` HL-clobber (above), misattributed to the memory window. So buffers may
  freely be PChars sources from WIN2. Moving `LINE_BUF` there freed 512 bytes of
  scarce WIN1 image space; during binary downloads its first 40 bytes temporarily
  hold the detached visible page's DOC descriptor. (STAGE/REQ_BUF/HIST_DATA stay
  in the same WIN2 GetMem page as plain memory.)
- `src/main.asm` rewritten: gopher rows parsed (`PARSE_ROW`: type/display/
  selector/host/port, TABs→NUL) and rendered straight from doc pages through the
  30-row viewport. **gopher+ menus (v0.1.11):** some servers (e.g. nihirash.net)
  append a 5th TAB field `+` after the port to flag gopher+ support. `PARSE_ROW`
  now calls `SCAN_FIELD` on the port field too, so the `+` tail is discarded;
  without it `PORT_CUR` became `"70\t+"`, the `AT+CIPSTART` port was malformed and
  EVERY link on such a menu failed to connect (and the link preview showed
  `...:70⇥+/1/mod`). We only send plain selectors, so servers reply with plain
  gopher (just the `+` line markers) — no gopher+ query handling is needed. **Menu vs text documents:** `DOC_TYPE_CUR` holds the gopher
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
  the next program isn't blocked. Page fetches temporarily use transparent
  `CIPMODE=1`, but `NET.RAW_FINISH` consumes the peer `CLOSED` or uses a guarded
  `+++` escape and restores `CIPMODE=0` before returning to the UI.
- **History:** stack of nav records `{kind,host,port,selector,type,sel,top}` in
  the WIN2 page (`HIST_DATA`), cap 16, oldest dropped on overflow. **Back
  re-fetches** the parent (network) or reloads home — a deliberate v1
  simplification of §4a's "no-refetch keep-the-page-chain" model (only ONE doc
  chain is alive at a time → far less memory/complexity; upgrade later).
- **Memory model — code in WIN1, runtime stack + buffers in the WIN2 GetMem
  page.** Code + small state live in WIN1 (loads at `0x4100`, image fits below
  `0x8000`). A single GetMem page mapped at WIN2 via `INIT_RUNTIME_PAGE` holds the
  scratch buffers (`STAGE`/`LINE_BUF`/`REQ_BUF`/`HIST_DATA`/`DL_BUF`, addresses in
  `console.inc`) **and the runtime stack** (top `RUN_STACK_TOP = 0xC000`, the top
  4 KB of the page, grows down). `SetWin2` is safe because no code lives in WIN2.
  Doc pages use WIN3 only (`OUT (#E2)` of a `EMM_FN5`-resolved page).
  - **Why the stack is in WIN2 (not WIN1 under the BSS):** the network-lib BSS
    sits just below `0x8000` in WIN1 (top ~`0x78xx`). An earlier model put the
    stack at `0x8000` growing down through that region, leaving only ~1.8 KB
    before the BSS — and a deep kit-receive chain plus the IDLE_CB clock draw
    overflowed into the BSS, corrupting the AT response (**"Network init
    failed"**). Putting the stack in the WIN2 page removes that coupling entirely.
  - **Boot vs runtime stack:** the EXE header's initial SP is `STACK_TOP = 0x8000`
    (a WIN1 *boot* stack) because WIN2 isn't ours yet at entry. `START` switches
    `SP = RUN_STACK_TOP` **right after `INIT_RUNTIME_PAGE`** maps the page (the
    early boot frames are dead — `START` exits via DSS, never RETs through them).
  - **Dss.Exec and the WIN2 stack — no juggling needed.** `Dss.Exec #40` swaps
    all of WIN1/WIN2/WIN3 for the child, but DSS **saves the parent's window
    registers (and SP) on entry and restores them on return** (`Execute.ASM`:
    `IN A,(SLOTn)`…`OUT (SLOTn),A`). And our WIN2 page is a **GetMem block tagged
    to our task**, so the child can't allocate over it (`FREE_PROCESS_MEMORY`
    frees only the child's pages). So the WIN2 runtime stack survives a child
    intact — `EXEC_PROGRAM` just runs the exec normally; no boot-stack switch, no
    `REMAP_WIN2`. (The corruption the old "never `SetWin2`" lore feared only
    happens if you map a page into WIN2/WIN3 that you did **not** GetMem — then
    the child can grab it as free memory and clobber it.)
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
- **Download progress** on the status bar: page fetches use `SHOW_PROGRESS`;
  binary receive paints `Receiving N KB` directly into text VRAM page `#50`
  (no DSS/BIOS call and no RTS pause), updating on whole-KB changes. Gopher has
  no content-length, so it is an amount, not a percent.
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
   (types `9`/`5`/`g`/`I`/`s`/`;`/`d`/`p` via `IS_BIN_TYPE`): `DOWNLOAD` saves to
   a file in `DOWNLOAD\` (`src/file.asm` = DSS Create `#0A`/
   Write `#14`/Close `#12`/MkDir `#1B`; backslash 8.3 paths) **without touching the
   current document or history** (dedicated `DL_HOST/DL_PORT/DL_SEL` buffers).
   Filename derived from the selector basename, sanitised to 8.3 (`MAKE_DLNAME` +
   `SANITIZE_CH`, fallback `INDEX.BIN`); status shows running/final size
   ("Receiving/Saved N KB", switching to MB for large files); Esc cancels (kit
   `CANCELLED`); disk-full → ERR_DISK.
   **THE TAIL-LOSS SAGA — root cause and the v0.1.9 fix.** Proven on REAL
   Sprinter+ESP (ESP-AT V2.2.1): downloads were byte-exact PREFIXES of their
   originals, losing a VARIABLE tail (428 B … 2903 B, < 1 TCP window), and
   `\r\nCLOSED` was never seen. The firmware **discards up to ~1-2 KB of
   un-relayed RX when the peer's FIN is processed while RTS is DEASSERTED**
   (i.e. during a slow append/flush). This is documented by the kit's OWN wget
   (`HOLD_TAIL_MARGIN EQU 8192`: it holds the last 8 KB in RAM with RTS asserted
   continuously across the close, "so ESP-AT never discards … the largest tail
   ESP can drop in one close"). wget knows where the end is from HTTP
   `Content-Length` (and can even re-`GET` the tail with `Range:`); **gopher has
   neither length nor range**, so we cannot know when to stop making
   RTS-deasserting gaps. ESP-AT **V2.2.1 also has no passive receive**
   (`CIPRECVMODE`/`CIPRECVDATA` absent — confirmed by the kit docs and a
   strings-scan of the flashed images; that would hold data past close and fix
   it deterministically). Transparent mode alone did NOT fix it (v0.1.8): pages
   survive only because their `.`-terminator arrives BEFORE the close; a binary
   stream's last data byte is flush against the FIN.
   **v0.1.10 keeps the drain-gate but returns binary downloads to ACTIVE +IPD
   mode** (`DL_RECV_LOOP`, `CIPMODE=0`). Transparent `CIPMODE=1` (v0.1.8/0.1.9)
   was a **regression on real hardware**: its byte-scanned `\r\nCLOSED` token
   often never arrived, so downloads hung ~5-8 s then failed "incomplete" (and
   still lost the tail) — the user confirmed downloads were **more stable without
   transparent mode**. The kit's own wget uses active mode; its `TCP.RECEIVE`
   returns **`RES_NOT_CONN` on a genuine peer CLOSED**, a reliable EOF that needs
   no in-band token. So the whole transparent token machinery is gone
   (`DL_FIND_CLOSED`, `DL_HOLD`, the withheld-tail split-token handling —
   deleted). Each `NET.RECV` is capped at **`DL_RECV_CAP` = 1499** (< the kit's
   `TCP_ACTIVE_IPD_MAX` = 1500) so `CAN_READ_ANOTHER_ACTIVE_IPD` skips its
   multi-frame peek and returns after ONE +IPD frame; the next read then observes
   `CLOSED` cleanly instead of swallowing it behind payload.
   The **tail protection is unchanged** — still wget's "RTS asserted across the
   close" without a length: bursts ACCUMULATE in `DL_BUF` with RTS held (wget's
   `RX_RESUME`-before / `RX_PAUSE`-after each read); the doc `DOC.APPEND` — the
   ONLY RTS-deasserting step — runs ONLY when a short `DL_CONT_TIMEOUT` (250 ms)
   continuation read returns `RES_RS_TIMEOUT`, i.e. the ESP is momentarily DRAINED
   (nothing queued to drop on FIN), or when the accumulator passes `DL_ACC_HIGH =
   DL_BUF_SIZE - DL_RECV_CAP` mid-stream (safe: data still flowing, FIN not
   pending). A standard gopher server sends the whole body then closes, so the
   last bytes always drain before the FIN and the `RES_NOT_CONN` is read gap-free.
   Per-burst VRAM progress (`DL_PROGRESS_ACC`, showing `recv_lo + dl_pending` =
   fill) keeps the counter advancing < every KB with no gap. A latched UART RX
   error (`TCP.LSR_ACCUM`, cleared by `NET.ACTIVE_PREP` + at loop top) rejects the
   whole stream. This makes a confirmed-`RES_NOT_CONN` download the norm — **and a
   confirmed download is always byte-correct** (EOF is the real close event, never
   a silence guess). A stall with no CLOSED is still reported incomplete →
   retry/keep prompt; retrying has a fresh chance. Flow: `NET.CONNECT` →
   `NET.ACTIVE_PREP` (clear LSR/parser, RTS up for the '>' prompt) → `NET.SEND`
   selector → `DL_RECV_LOOP` → `NET.CLOSE`; the visible page is detached
   (`DOC.SAVE_STATE`→`LINE_BUF` + `DOC.NEW`, restored via `DL_RESTORE_DOC` on every
   exit). **INVARIANT — a receive loop must leave RTS ASSERTED on exit:**
   `DL_RECV_LOOP`'s last act is `RX_PAUSE`, so both its `.done` and `.fail` exits
   call `NET.RX_RESUME` before returning. Without it the ESP (RTS gates its UART
   TX) can't answer `NET.CLOSE`'s `AT+CIPCLOSE` (stale socket lingers) NOR the next
   fetch's first AT command — the transparent `RAW_CONNECT` does NOT re-assert RTS
   itself (only `NET.CONNECT.prep` does), so after a download it would fail every
   page with "Connect failed". (This bit v0.1.10 the moment the active loop
   replaced the transparent one, which had resumed RTS in `RAW_FINISH`.)
   Page fetches STILL use transparent `CIPMODE=1` (their `.`-terminator
   arrives before the close, so the token IS reliable there — see below); the two
   transports interleave cleanly because each restores `CIPMODE=0` when done.
   **Residual limit:** if a server streams with no ≥250 ms gap right up to a
   buffer-full flush that the FIN coincides with, a tail can still drop — then no
   `RES_NOT_CONN`, so it fails VISIBLY (incomplete → retry), never silent
   corruption. The only deterministic 100% fix is passive-receive firmware (or a
   length-bearing protocol like the kit's HTTP wget). **File size is NOT capped:** at the `DOC_MAX_PAGES` (256 KB) cap
   `DL_MIDFLUSH` writes the chain's whole sectors, carries the sub-sector tail
   (0..511 B, via `DL_BUF`) into a fresh chain, and receiving continues — mid-
   file FAT writes stay 512-aligned. The mid-flush RTS pause is safe **mid-stream**
   (data still flowing, so no FIN is pending and no queued `+IPD` frame is at
   risk); it is only the FIN-coincident append gap that the drain-gate guards.
   Note DSS `Write #14` itself
   flushes a sub-sector final write immediately (read-modify-write of the last
   sector + `F_SIZE` update), so a non-sector-aligned file length is written
   faithfully — sector-aligned truncation in a bad download is a symptom of an
   OLDER streaming binary, not the current write path.
   **Incomplete-transfer outcome is the user's choice** (`CONFIRM_KEEP`): when
   a clean prefix was received but the transfer didn't finish (timeout, missing
   `CLOSED`, post-flush purge), the status asks "R = delete + retry, any other
   key = keep the file". Retry deletes and restarts the whole download
   (`JP DOWNLOAD`); keep persists the received prefix via the normal write
   phase, shows "Saved N KB ... (partial)" and suppresses the open-in-viewer
   offer (`dl_partial`). Cancel and UART/disk/memory faults still auto-delete
   (that data is untrustworthy or unwanted).
   `doc_trunc` mid-receive now only means GetMem refused a page (→
   `MSG_MEM_ERR`, code 4 in `dl_disk_err`). After `CLOSED`: `SHOW_WRITING`, then
   `DL_WRITE_DOC` walks the chain and writes through `DL_BUF` in 4 KB staged
   chunks (a DSS call must never read from a WIN3-mapped page) — every FAT
   write is 8 whole sectors except the file's final chunk; FAT writes with RTS
   low are safe here because the peer already closed. `DL_RESTORE_DOC`
   (`DOC.RESET` + `DOC.LOAD_STATE`) runs on success and on every error path
   after the detach. The clock `IDLE_CB` is disabled during receive. Each
   `NET.RECV` stays capped at `TCP_ACTIVE_IPD_MAX-1` so `TCP.RECEIVE` can never
   swallow `CLOSED` behind payload. Progress ("Receiving
   N KB") updates on every whole-KB change (each `+IPD` frame is ≤ 1.5 KB, so
   at least every ~1.5 KB) via `DL_PROGRESS_RX`/`DLP_DRAW` — painted **directly
   into text VRAM** (WIN3→page `#50`, `PORT_Y #89` selects the column, symbol
   `#C301+row*4`, attr next byte, park `#C0`, DI around the burst, save/restore
   WIN3 via `IN A,(#E2)` — readable, the BIOS `LP_OPEN_PG` does the same): no
   DSS/BIOS call, no RTS pause; the TL16C550 auto-RTS (AFE) covers the ~0.2 ms
   burst. **The PORT_Y base is computed, never probed.** Immediately after
   `WCOMMON.INIT_VMODE` selects 80×32, `INIT_PROGRESS_VRAM` calls DSS
   `GetVMod #51` (`B` = active text screen 0/1). BIOS `WIN_OPEN_W1` gives
   `H_BEG=#01` for screen 0 and `#81` for screen 1; the status starts at logical
   column 1, so `dlp_base = #02 | (B<<7)` (`#02`/`#82`). The screen number is
   saved in `video_page`; after an external viewer `EXEC_PROGRAM` explicitly
   passes that page in `B` while reasserting mode `#03`. Thus every in-stream
   update always takes the direct VRAM path; there is no DSS fallback or
   screen-content search. **Invariant: NOTHING in the receive loop may call
   `NET.RX_PAUSE`.**
   The pre-0.1.7 fallback paused RTS around each draw and that was the
   remaining tail-killer on real HW (ESP-AT V2.2.1): the firmware drops queued
   `+IPD` frames when the peer's FIN is processed while the relay is blocked,
   so every paused draw was a purge window — files of all sizes truncated by a
   VARIABLE amount (repeat downloads gave different lengths). The real card's
   V2.2.1 firmware has NO passive receive (`CIPRECVMODE`/`CIPRECVDATA` absent
   per the kit's strings-scan of the images — see network/AGENTS.md), so
   pull-paced receive is not available; if variable truncation ever survives a
   genuinely pause-free receive, the remaining cure is firmware-level (flash an
   AT build with passive receive, e.g. NONOS AT 1.7.5, and add a
   `CIPRECVDATA` receive path gated on detection). (A historical hazard to keep in mind for any future buffer
   compaction: `LDIR` with `BC=0` copies 64 KB — the old streaming flush hit
   exactly that whenever the EOF remainder was a multiple of 512 and destroyed
   the whole address space.)

   A subtle kit behaviour was the immediate cause of false incomplete results:
   `TCP.RECEIVE` normally peeks for another frame when at least 1500 bytes remain.
   If that peek consumed `CLOSED` after already storing data, it returned the data
   successfully and forgot the close reason; the next call could only time out.
   Every receive is capped at 1499 bytes, forcing it to return after
   the current length-framed payload so the following call observes `CLOSED`
   explicitly. Only that real `RES_NOT_CONN` result is accepted as EOF; cancel,
   disk error, or any latched UART OE/PE/FE/BI/RCVE bit deletes the partial
   file, while a clean-prefix timeout/parser-error prompts retry-or-keep (see
   above). This applies uniformly to ZIP, MOD, GIF, images and
   arbitrary binary types; there is no format-specific completeness patch. The
   progress/final byte counter is 32-bit.
   **Open-in-viewer — DONE:**
   after a download `MAYBE_OPEN_DOWNLOAD` takes the file's extension (`DL_EXT_PTR`),
   `CFG.VIEWER_FOR_EXT` looks up the program; unless the `skip_ask_for_exec` setting
   is truthy (`SKIP_ASK`) it asks (`CONFIRM_OPEN`, Y/N), then `CFG.BUILD_CMD` expands
   `%file%`→`FILE_ABS` (`EXE_DIR`+`DOWNLOAD\name`). The viewer command (a full EXE
   path + the file arg) is launched **directly** via **Dss.Exec `#40`** (`HL`=cmd,
   `BC`=`#0040`, B=0), like FlexNavigator's `RunFile`. `EXEC_PROGRAM` saves/restores
   `SP`, re-maps our WIN2 page (`REMAP_WIN2`, handle in `win2_block`), `CHDIR_EXE`
   back to the EXE dir, and re-asserts 80x32 (`SetVMod #50 A=#03`) on return; then
   `REDRAW_FULL`. (Confirmed working on target.) Two bugs fixed during bring-up:
   (1) `CFG.TRIM_TRAIL` clobbered `DE` (the value pointer) → every viewer template
   parsed EMPTY → launched an empty command; now PUSH/POPs DE. (2) Routing through
   `SYSTEM.EXE /C` dropped into an interactive shell eating garbage - direct `#40`
   is correct for an EXE viewer (the shell wrapper is only for `.bat`).
   **Type `h` (URL links) — DONE.** `ON_ENTER` `.urllink`: the selector is a URL,
   usually `URL:<url>`; `STRIP_URL_PREFIX` drops a leading `URL:` (CI). If the URL
   is `gopher://host[:port][/<type><selector>]` (`SKIP_PREFIX_CI`), `PARSE_GOPHER_URL`
   fills `HOST_CUR/PORT_CUR`(def 70)`/SEL_CUR/DOC_TYPE_CUR`(def `1`) and it's fetched
   like a normal link (PUSH_HIST + GOTO_FETCH). For any other scheme (`GET_URL_SCHEME`
   → `http`/`ftp`/`mailto`/…) it looks the scheme up in the **`[urls]`** section of
   GOPHER.CFG (`CFG.HANDLER_FOR_SCHEME`; `scheme = program %url%`). If a handler is
   configured: show the URL on the header (`SHOW_URL_HEADER`), confirm
   (`CONFIRM_OPEN`, unless `skip_ask_for_exec`), then `CFG.BUILD_CMD` (expands
   `%url%`) + `EXEC_PROGRAM`. No handler → `SHOW_WEBLINK` shows `Web link: <url>` on
   the status bar. CFG: `[viewers]` (ext→`%file%`) and `[urls]` (scheme→`%url%`)
   share one on-demand lookup (`LOOKUP` with `lookup_sec`); `BUILD_CMD` expands both
   `%file%` and `%url%`.
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
2a. **Config file `GOPHER.CFG` (next to the EXE) — reading + parsing DONE
   (`src/cfg.asm`, MODULE CFG).** INI-style with two sections separated so settings
   and the program map don't mix: **`[settings]`** (generic `key=value`, reserved
   for future options) and **`[viewers]`** (`ext = program %file%` — `%file%` is
   replaced with the saved file's path at launch; program path abs or rel). `#`/`;`
   comments, blank lines ignored; section & ext names compared case-insensitively.
   The file is **streamed** through `STAGE` in chunks (size is NOT bounded by a
   fixed buffer) and assembled line by line in a WIN2 accumulator (`CFG_LINE`).
   **Only `[settings]` are kept** (a tiny WIN1 pool `ST_POOL`/`st_key`/`st_val`,
   since they're needed throughout a run); the **`[viewers]` map is NOT kept** —
   `CFG.VIEWER_FOR_EXT` re-scans the file **on demand** (a rare action: opening a
   just-downloaded file) and copies just the one matching command into `CMD_TPL`.
   This keeps persistent memory tiny and removes the earlier fixed `CFG_RAW@0xA000`
   buffer (which was fine for space — code is WIN1, can't reach WIN2 — but an
   arbitrary cap). `CFG.LOAD` (START) parses settings; `CFG.VIEWER_FOR_EXT`
   (HL=ext→DE=cmd, CF), `CFG.SETTING` (HL=key→DE=val, CF), `CFG.BUILD_CMD`
   (HL=tmpl, DE=path→`CMD_BUF`) expands every `%file%`. Sample in `data/gopher.cfg`
   (not auto-deployed; drop next to GOPHER.EXE to use).
   **Still TODO (the actual use):** on a finished download, look up the ext, show a
   confirm prompt, `CFG.BUILD_CMD` + `Dss.Exec` the viewer; and consume a
   `downloaddir` setting to override `DOWNLOAD\`.
3. **Cancel during the network phase — DONE.** Esc (also Ctrl+Z) cancels both
   Fetching and Loading: the kit polls `WCOMMON.CHECK_CANCEL_IN_ISA` inside its
   UART/TCP/RECEIVE byte-waits and sets `WCOMMON.CANCELLED`; we clear it at fetch
   start, abort retries (`AT_RECOVER`/`CONNECT`) on cancel, and `FETCH_ERR` shows
   "Cancelled". (Note: cancel during `WIFI.UART_FIND` at the very start of INIT is
   not polled by the kit, so the first ~moment isn't cancellable — minor.)
4. **Clock in the header — DONE.** `CLOCK_TICK` (called each main-loop spin) reads
   DSS `SYSTIME #21` (`H`=hours, `L`=minutes, `B`=seconds, decimal) and paints
   "HH:MM:SS" in the header's right corner (cols 71-78, `ATTR_HEADER`) only when the
   second changes (`clk_last`; `PUT2D` formats each 0-99 field). `DRAW_HEADER` sets
   `clk_last=0xFF` so its full-row fill doesn't leave the clock blank.
5. **Ctrl+S** — save the current document to a file (DSS file API).
6. **Ctrl+D — add the current page to bookmarks — DONE.** `ON_ADD_BOOKMARK`
   appends one type-1 gopher record `"<type><title> TAB <selector> TAB <host> TAB
   <port> CRLF"` (built in `BM_LINE`, WIN1) to `BOOKMARK.GPH` next to the EXE. Only
   network pages are bookmarkable — the home/bookmarks pages have an empty
   `HOST_CUR` and are skipped ("Nothing to bookmark"). `APPEND_BM_LINE` opens the
   file `FM_READ_WRITE`, `MOVE_FP SEEK_END`, `DSS_WRITE`; if the open fails (no
   file yet) it creates one with the proven `#0A` create/overwrite call first.
   **Ctrl-combo detection (subtle — got it wrong first):** the DSS keyboard
   driver (`KEYINTER.ASM`) emits **no symbolic code for a Ctrl+letter** (A/E = 0),
   so checking the ASCII/control byte never fires. The combo is recognised by the
   shift-state mask in **B** (bit 5 = Ctrl; B per the manual's `#30-#37` contract,
   NOT C which is the layout/RUS-LAT mode) plus the **physical keycode in D**
   (`AND 0x7F`): `KEY_B`=`0x2E`, `KEY_D`=`0x1F`. Those D codes are the driver's
   `XLAT_T[]` outputs for the B/D keys (AT set-2 `0x32`/`0x23`), cross-checked
   against the texteditor's Ctrl+Y/C/V/X codes (`0x15`/`0x2C`/`0x2D`/`0x2B`).
   `ScanKey` still returns NZ ("key present") for a Ctrl+letter even though A=0,
   so `KBD.SCAN` sees it.
6a. **Home page externalised out of the code image — DONE** (frees ~1.2 KB; the
   home page is now editable in `data/index.gph`). **Priority at startup
   (`LOAD_HOME`): external `INDEX.GPH` in the EXE dir → appended-to-EXE copy →
   tiny built-in stub.** `LOAD_HOME_DISK` opens a relative `INDEX.GPH` (we chdir'd
   into the EXE dir, so it resolves next to GOPHER.EXE) read-only and, if present
   and non-empty, loads it — letting the user override the home page WITHOUT
   rebuilding. The shared chunked reader is `READ_INTO_DOC` (A=handle, `hf_rem`
   bytes → `DOC.APPEND`). The appended copy is the bundled default:
   **GOPHER.EXE is a *loader EXE* with the home page appended past the image** (the
   fn/kode/tasm/spevosdk idiom). Key correction over the first plan: a `--raw` EXE does NOT
   ignore appended bytes — the no-loader DSS path (`Execute.ASM .RET_1`) reads to
   EOF and CLOSES the file. So instead we set the **`LOADER` header word at offset
   `0x08`** = `IMAGE_END - LOAD_ADDR` (sjasmplus, ~`0x2DAB`); DSS then loads exactly
   the image via the `PRELOAD`/`_RET_2` path and leaves the EXE **open** (FM at
   `(IX-3)`, FP right after the image). `IMAGE_END` is a label after the last
   `INCLUDE`. The file is `[512 hdr][image LOADER bytes][INDEX.GPH]`; appended data
   starts at file offset `HOME_OFFSET = 0x200 + LOADER`.
   - **Build (Makefile):** `cat data/index.gph >> build/GOPHER.EXE` after sjasmplus
     (CRLF + real TABs; `NEXT_LINE` tolerates CRLF or LF).
   - **Runtime (`LOAD_HOME_FILE`):** capture `home_fm` = `(IX-3)` as the FIRST
     instruction in START (before IX is clobbered); `MOVE_FP SEEK_END` → size;
     `len = size - HOME_OFFSET`; `MOVE_FP SEEK_SET HOME_OFFSET`; loop
     `DSS_READ_FILE`→`STAGE`→`DOC.APPEND`. `LOAD_HOME` falls back to a tiny built-in
     `WELCOME_DOC` stub if `home_fm`=`0xFF`/`len<=0` (older DSS that closes the EXE,
     or a non-loader build). PRELOAD sizes memory by `LOADER`, NOT file length, so
     appending doesn't change allocation. NEEDS on-target check that the loader
     path works on BIOS v3.06 and FM stays open.
6b. **Bookmarks file `BOOKMARK.GPH` next to the EXE, opened by Ctrl+B — DONE.**
   (8.3 name — `bookmarks.gph` would need an LFN; DSS is FAT16/8.3.) `ON_BOOKMARKS`
   browses it as a normal local type-1 menu: `PUSH_HIST` + `DOC.NEW` (so Backspace
   returns), then the shared `LOAD_DISK_GPH` (HL=name; refactored out of
   `LOAD_HOME_DISK`) reads the whole file into the doc. `cur_kind=0`/empty
   `HOST_CUR` mark it local (no "Loaded N bytes", not re-bookmarkable). If the file
   is absent/empty a built-in `BM_EMPTY_DOC` placeholder ("No bookmarks yet…") is
   shown instead. Ctrl+D (item 6) appends.
6c. **Ctrl+G — open an arbitrary address**: a text-input prompt (host[:port][/sel])
   then fetch it.
7. **Empty/truncated doc hardening — DONE, awaiting transparent-mode target
   check.** The status
   bar shows the loaded size and flags "- INCOMPLETE" when the gopher "."
   terminator was never received (`doc_complete`, `SHOW_LOADED`). The recurring
   ~2 KB truncation was the ESP-AT FIN/RTS tail-drop: `RECV_LOOP` manually lowered
   RTS after every 2 KB `STAGE` block, and if FIN arrived while RTS was low the
   ESP could discard queued `+IPD` tail bytes. Page receive now keeps manual RTS
   asserted continuously until it sees the gopher dot terminator; between blocks
   it only scans the terminator and does a fast `DOC.APPEND`. Receive uses the
   shared 4 KB `DL_BUF` (safe after NETCFG init, and mutually exclusive with a
   binary download), and the first doc page is preallocated before the request.
   Per-block DSS progress/clock drawing is deferred until receive stops. The
   terminator scanner is stateful across block boundaries and accepts CRLF/LF.
   The first continuous-RTS version still truncated on target. Diagnostics were
   decisive: `rx=6` = clean peer `CLOSED`, while `lsr=97` (`0x61`) has no UART
   overrun/parity/framing bits. A resume-by-refetch experiment also reached the
   identical prefix, proving the loss is inside jesperl's active `+IPD` FIN path,
   not the browser's append/parser. The firmware has no passive-receive commands,
   so **page fetches now use transparent `CIPMODE=1`** (the proven telnet raw-UART
   transport): selector+CRLF is sent directly, response bytes bypass `+IPD`, and
   `RECV_LOOP` drains until the gopher terminator plus ESP `CLOSED`. Cleanup
   restores command mode/CIPMODE=0; timeout/cancel uses the guarded `+++` escape.
   Applying that transparent transport to binary downloads was a failed
   experiment: fresh target ZIPs were exact prefixes of their local-server
   originals (8760/11095 and 24820/26676), and only about one transfer in ten
   completed. Raw mode provides neither `+IPD` lengths nor a reliable close event
   on this firmware, so its silence-based EOF guess was fundamentally unsafe.
   **v0.1.5 returns binary downloads to active `+IPD` mode** while leaving page
   fetches transparent. The active receiver is capped below the kit's 1500-byte
   multi-frame-peek threshold so `CLOSED` cannot be swallowed after payload;
   streaming, aligned FAT writes, progress, cancellation and UART-error rejection
   remain in place for every binary type. **(v0.1.8/0.1.9 mistakenly re-tried
   transparent mode for binary downloads and it failed on real HW exactly as this
   note warned — hung with no `\r\nCLOSED`, still lost the tail. v0.1.10 reverted
   to active `+IPD` for good; see the `DL_RECV_LOOP` section above. Do NOT put
   binary downloads back on transparent mode: the firmware gives no reliable close
   event there.)**
   **Raw-connect latency fix:** the first transparent build still called the old
   `CONNECT` wrapper, whose unconditional pre-`CIPCLOSE` waited 5 s when the peer
   had already closed normally. `RAW_CONNECT` now tries `TCP.OPEN` directly on the
   normal clean path; the close/drain/retry wrapper is used only after a genuine
   open failure. This removes the repeatable ~5 s pause without weakening recovery.
   **Post-terminator latency fix:** jesperl may return to AT mode silently, without
   putting the expected `CLOSED` token in the UART. Waiting for it with the normal
   15 s receive timeout made tiny pages appear to hang for ~12–13 s. Once the dot
   terminator is owned, `RECV_LOOP` now waits only a 750 ms close grace. On silence,
   `RAW_FINISH` probes `AT`: an immediate OK takes the fast cleanup path; only a
   failed probe uses `+++`. Its standards-required guard is 1.2 s per side (was the
   telnet utility's conservative 2 s), so even the exceptional escape is bounded.
   A further target trace showed a complete page appearing only after the long
   timeout: `COUNT_LINES` accepted a terminal `.` at quiet EOF, while the streaming
   scanner was still waiting for its LF (`recv_line_state=1`). That pending-dot
   state now also selects the 750 ms close grace and is promoted to a complete
   terminator on quiet EOF. After `RAW_CONNECT`, the status changes from
   `Fetching...` to `Loading 0 bytes`, giving an explicit phase marker if any
   remaining delay is in init/connect versus receive/cleanup.

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
15. **"Back to previous page" links should act like Backspace.** Many gopher
   menus include an explicit *go up/back* item (e.g. a type-`1` link displayed as
   "Back to previous page" / "Back to home page", often with selector `/` or the
   parent path). Right now following it FETCHES the parent and PUSHES a new history
   level, so the history grows instead of unwinding. Detect such links and route
   them to `ON_BACK` (pop history, no re-fetch) instead of `.follow`. Detection
   options: (a) match the display text against a small set of phrases ("back",
   "previous", "up", "..", "parent"); (b) if the link's host/port/selector equals
   the previous history record's, treat Enter as Back. (a) is simplest; (b) is more
   robust but only catches the immediate parent. Consider both (phrase OR matches-
   parent) and fall back to a normal fetch if neither.

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
- Direct text VRAM (fast path): VRAM page `#50` into WIN3, `PORT_Y #89` selects
  column; each row entry is `(mode, sym, attr, modex)` at `#C300+row*4`, so the
  printable symbol is written at `#C301+row*4`. Park `PORT_Y=#C0` afterwards.

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

> ⚠️ **Superseded in part.** The "flat WIN1+WIN2 image, never `SetWin2`, stack at
> `0xBFFF`" design below was the Phase-2 *theory* and was **not** adopted. The
> implemented model (see §2 "Memory model") is: **code in WIN1; a GetMem page
> mapped at WIN2 via `SetWin2` holds the scratch buffers AND the runtime stack
> (`RUN_STACK_TOP = 0xC000`).** `SetWin2` is used and safe (no code in WIN2). Only
> the WIN3 ISA/doc-page time-sharing rule below still holds verbatim.

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

**Versioning.** App version is `DEFINE APP_VERSION "0.1"` in
`src/include/app_version.inc` (bump on release; major.minor, optional patch like
`0.1.12`). The build date/time is auto-stamped: the Makefile regenerates
`build/buildinfo.inc` (`DEFINE BUILD_DATETIME "DD.MM.YYYY HH:MM"`) every build
(needs `-I $(BUILD)`). Both feed `MSG_BANNER`, printed by `SHOW_BANNER` at startup
and on exit (after CLS): `GOPHER Browser v.0.1 (…)\r\nby Dmitry Mikhalchenkov
(SprinterTeam)`. (Don't call our file `version.inc` — the network kit ships one and
the `-I` paths would shadow ours. `EXE_VERSION` is the DSS EXE-format version, not
the app version.)

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
- **Network kit BSS must stay clear of the WIN2 page (0x8000).** The kit anchors
  its BSS (`RS_BUFF`, ESP-TCP buffers, netcfg's 2 KB `CFG_BUFF`) right after the
  WIN1 image. As the app grows, that chain creeps up; if it crosses `0x8000` it
  straddles the WIN1/WIN2 page boundary and overlaps the WIN2 scratch buffers
  (`STAGE` etc.), silently corrupting receives and hanging every fetch. Fix used:
  `DEFINE NETCFG_BSS_BASE_OVERRIDE` + `NETCFG_BSS_BASE EQU DL_BUF` relocates the
  big netcfg BSS wholly into the WIN2 page (its config-load lifetime is disjoint
  from `DL_BUF`'s download use). Build-time `ASSERT`s after the kit INCLUDEs guard
  `TCP.TCP_BSS_END <= 0x8000` and netcfg-within-`DL_BUF`, so future growth fails
  the build instead of corrupting at runtime. (If TCP BSS later nears 0x8000,
  relocate it too via `ESP_TCP_BSS_BASE_OVERRIDE`.)
  When the image itself nears the limit, move runtime-only buffers into the
  WIN2 scratch page instead (v0.1.6: `DL_NAME`/`DL_PATH` became WIN2 EQUs at
  `0x9F80`/`0x9F90` for exactly this reason; headroom after that ≈ 35 bytes,
  the ASSERT still guards it).
- **`net_inited` caching can strand a stale ESP session.** `NET.INIT` runs once
  and is cached (`net_inited=1`); later fetches reuse the open UART/ESP session.
  If that session goes stale (e.g. after the user lingers on a local page — the
  Ctrl+B bookmarks page or home — between network fetches), the next `TCP.OPEN`
  can hang on "Fetching..." and, because the flag stays 1, never recover. Remedy:
  call `INVALIDATE_NET` when leaving such a path so the next fetch re-runs
  `NET.INIT` (full UART re-init + AT + drain, no ISA_RESET). **This is NOT because
  file I/O corrupts the card** — verified the kit brackets every UART access with
  `ISA_OPEN/ISA_CLOSE` (save/restore WIN3), which is exactly why a chunked download
  (interleaved `RECV` + `FILE.WRITE` on one open socket) keeps working. The
  `EXEC_PROGRAM` re-init is for a different reason: a child program can reprogram
  the ISA card directly. **Confirmed on target:** `INVALIDATE_NET` after the Ctrl+B
  bookmarks detour fixes the "fetch hangs after bookmarks" report. (The deeper
  trigger of the staleness wasn't instrumented; a long idle on a *network* page
  could plausibly strand the session the same way — if that ever surfaces, re-init
  on connect-failure or before any fetch following an idle gap would generalise it.)
- **`MAINLOOP` dispatch is `JP`-based** (`JP Z, ON_x`), so a key handler runs with
  an empty stack (`SP = RUN_STACK_TOP`). A handler MUST end by `JP MAINLOOP` — it
  must NOT tail-jump into a routine that ends in `RET` (e.g. `JP SET_STATUS`,
  which RETs via `TERM.PUTS`): that `RET` pops garbage above the WIN2 page and
  hangs. Use `CALL SET_STATUS` + `JP MAINLOOP`. (Bit both `ON_ADD_BOOKMARK` and
  the older `.h_execfail`.) A bare `JP SET_STATUS` is only OK as a tail-call
  inside a routine that was itself `CALL`ed (e.g. `SHOW_ERROR`, `SHOW_DOC_STATUS`).

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
