# CLAUDE.md — Moon Rabbit (Gopher browser for Sprinter)

> Project guidance for AI agents and developers. Keep this file current as the
> port progresses. See `plan.md` for the staged porting plan.

## 1. What this project is

A **Gopher protocol browser for the Sprinter computer** (a Z80-based ZX Spectrum
clone), running under **DSS** in the native **80×32 text mode**.

It is a port of the **Moon Rabbit / Internet NEXTplorer** lineage of Z80 gopher
browsers by *nihirash*. We take the most recent **pure‑Z80** core
(`internet-nextplorer`) as the base, and adopt the cleaner architecture ideas
from the newest `agon-snail` (transport/fetcher split, `file://` transport).

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

Next: **Phase 2** — ESP network backend + `NET.CFG` behind the `NET.*` HAL; fetch
a real gopher menu into the buffer (then Phase 3 wires it to this renderer).

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
