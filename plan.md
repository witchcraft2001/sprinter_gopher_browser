# Porting Plan — Moon Rabbit Gopher browser → Sprinter (DSS, 80×32 text)

Status: **draft / approved direction.** See `CLAUDE.md` for platform facts.

## 1. Goal

A Gopher browser running on **Sprinter** under **DSS**, in the native **80×32
text mode**, networking over the **ESP Wi-Fi card** (default) with the ability to
**rebuild for the NE2000/RTL8019AS ISA Ethernet card** by flipping one build
switch. Single Z80 codebase, `sjasmplus`, output `GOPHER.EXE` (working name).

## 2. Which repo to port — analysis & conclusion

The three candidate repos are **one lineage** by *nihirash* — the same gopher
browser re-targeted across platforms:

| Repo | Last commit | CPU / toolchain | Display | Net | Verdict |
|------|-------------|-----------------|---------|-----|---------|
| `moon-rabbit-zx` | Oct 2022 | Z80 / sjasmplus | Timex 32/80-col | ESP-AT (+proxy) | oldest, stalled, needs proxy |
| `internet-nextplorer` | Dec 2023 | **Z80** / sjasmplus | 80×25 tiles (Next) | ESP-AT (+proxy) | **most recent pure-Z80**; multilevel history, downloads, search |
| `agon-snail` | Aug 2024 | **eZ80** / agon-ez80asm | VDP via MOS | ESP via MOS UART | newest & cleanest arch, but eZ80 + MOS (not Z80-portable) |

**Conclusion — base = `internet-nextplorer`, enriched with `agon-snail` ideas.**

- Sprinter is a **Z80** machine. `agon-snail` is the newest and architecturally
  cleanest, but it is **eZ80 assembly + MOS** — its opcodes and OS calls cannot be
  reused directly, only its *design*.
- `internet-nextplorer` is the **most recent pure-Z80** version of the core, is
  already **80 columns**, uses `sjasmplus` (our toolchain), and has the most
  evolved features in the Z80 branch (multilevel history, file downloads, type-7
  search). Its hardware coupling (Next tiles, Next UART, proxy) is exactly the
  part we are replacing anyway.
- We **adopt from `agon-snail`** its cleaner separation: a `fetcher`/transport
  router that dispatches on scheme so `network`, `file://`, and the built-in
  `home://` page all flow through one path.

We also **drop the proxy** entirely: NEXTplorer needs it only because the ZX Next
UART has no flow control; Sprinter's TL16C550 provides RTS/CTS hardware flow
control, and the Sprinter ESP kit already uses it (`WCOMMON.SETUP_UART_FLOW`).

## 3. Architecture overview

```
                +------------------------------------------+
                |        Gopher core (from NEXTplorer)     |
                |  fetcher / engine / history / urlencode  |
                |  render (gopher-page,row,plaintext,ui)   |
                +---------------+--------------+-----------+
                                |              |
                    NET.* HAL   |              |  TERM.* / KBD.* / FILE.*
                                |              |  (DSS 80x32 text, ScanKey, DSS files)
              +-----------------+              +--------------------+
              |                                                     |
     -DBACKEND_ESP                                         -DBACKEND_NE2000
   sprinter_wifi/network libs                       sprinter-rtl8019a libs
   (isa,esplib,esp_tcp,netcfg,wcommon)              (isa,rtl8019,resolve,dns,tcp,arp)
              \___________________  NET.CFG  ___________________/
```

The gopher core never touches hardware directly — it calls `NET.*`, `TERM.*`,
`KBD.*`, `FILE.*`. Backends are selected at assembly time.

## 4. Reuse vs. replace (internet-nextplorer modules)

**Keep (logic), rewire I/O:**
- `engine/fetcher.asm`, `engine/engine.asm` — net calls → `NET.*`
- `engine/history/{controller,index,model}.asm` — multilevel history
- `engine/urlencoder.asm`, `engine/media-processor.asm`, `engine/downloader.asm`
- `utils/limitedstring.asm`, `utils/comparebuff.asm`

**Adapt (render to DSS text):**
- `render/{gopher-page,row,plaintext,dialogbox,ui,buffer}.asm` — emit 80×32 text
  via `TERM.*` instead of Next tilemap.

**Replace:**
- `drivers/{tile-driver,font,next}.asm` → `term.asm` (DSS 80×32 text driver)
- `drivers/{keyboard,input,joystick}.asm` → `kbd.asm` (DSS `ScanKey #31`)
- `drivers/{uart,wifi}.asm` + `drivers/proxy.asm` → `net.asm` HAL (**proxy dropped**)
- `drivers/esxdos.asm` → `file.asm` (DSS file API)
- `main.asm` (`SAVENEX`, `nextreg`, `ORG #38` IM) → DSS EXE entry/startup

**Defer (optional, later):** `player/*` (AY/Vortex music), `screen-viewer/*`
(image viewing). Not required for a working browser.

## 5. Network HAL contract

```
NET.INIT    -> detect card, NETCFG.LOAD, bring link up. CF=1 if no/failed HW
NET.CONNECT  HL=host ASCIIZ, DE=port ASCIIZ -> open TCP. CF=1 on fail
NET.SEND     HL=buf, BC=len        ; send all
NET.RECV     HL=buf, BC=max, DE=timeout(ms) -> BC=bytes (0=none, CF=1 on error)
NET.CLOSE
NET.STATUS   -> A = state (NO_HW / LINK_DOWN / LINK_UP / CONNECTED)
```

- **ESP** (`BACKEND_ESP`): `NET.CONNECT` = `TCP.OPEN` (ESP resolves DNS itself);
  `NET.SEND` = `TCP.SEND_BUFFER`; `NET.RECV` = `TCP.RECEIVE` (bracket processing
  with `WIFI.UART_RX_PAUSE/RESUME`); `NET.INIT` = ISA_RESET → UART_FIND →
  NETCFG.LOAD/APPLY_UART_BAUD → UART_INIT → SETUP_UART_FLOW.
- **NE2000** (`BACKEND_NE2000`): `NET.CONNECT` = `RESOLVE.HOST` →
  `RESOLVE.NEXT_HOP_FOR` → set `TCP_REMOTE_IP/MAC/PORT` → `TCP.OPEN`; then
  `TCP.SEND` / `TCP.RECV` / `TCP.CLOSE`. `NET.INIT` = `RTL.INIT_BASE` →
  `RTL.INIT_NORMAL` + config MAC/IP.

Both honor the same `NET.CFG`; Wi-Fi join is performed once by `NETUP.EXE`.

## 6. Proposed repository layout

```
moonrabbit/
  CLAUDE.md  plan.md  README.md  Makefile
  src/
    main.asm                 ; DSS EXE header + entry + main loop
    net/
      net.asm                ; HAL dispatch (IFDEF BACKEND_*)
      backend_esp.asm        ; wraps sprinter_wifi libs
      backend_ne2000.asm     ; wraps sprinter-rtl8019a libs
    term.asm  kbd.asm  file.asm
    engine/   (fetcher, engine, history/, urlencoder, media, downloader)
    render/   (gopher-page, row, plaintext, dialogbox, ui, buffer)
    include/  (dss.inc, macro.inc, sprinter.inc — from kits)
    lib/      (vendored net-kit lib modules, per backend)
  data/   (home page .gph, fonts if any)
  build/  (GOPHER.EXE, .lst — gitignored)
  distr/  (FAT12 image)
  tools/  (build.sh, image.sh, md2txt.py)
```

## 7. Phased implementation

**Phase 0 — Toolchain & skeleton**
- `sjasmplus` available; vendor `dss.inc`/`macro.inc`/`sprinter.inc` from a kit.
- "Hello" DSS `.EXE`: set 80×32 (`SetVMod #03`), `PChars`, `ScanKey`, clean `Exit`.
- Verify it runs (MAME Sprinter / real HW). Establishes EXE header + build.

**Phase 1 — Platform HAL**
- `term.asm`: clear, locate, print string, print row with attribute, scroll
  (BIOS `#8A`), highlighted/selected line.
- `kbd.asm`: non-blocking key read + nav-key map (↑↓ ←→ Enter Esc PgUp/Dn Home/End Backspace).
- `file.asm`: open/read/write/close + dir listing (for `file://`).
- Milestone: render a static gopher menu from an embedded buffer; cursor
  navigation and scrolling work in 80×32.

**Phase 2 — ESP network backend + NET.CFG**
- Vendor ESP libs; implement `net.asm` + `backend_esp.asm` against the HAL.
- `NET.INIT`/`CONNECT`/`SEND`/`RECV`/`CLOSE`; load `NET.CFG`; assume `NETUP` joined Wi-Fi.
- Milestone: fetch a real gopher menu (e.g. `gopher.floodgap.com`) into the buffer.

**Phase 3 — Gopher engine integration (end-to-end)**
- Port `engine/fetcher` + `render/*`; parse menu rows (type/display/selector/host/port);
  follow links; render text (type 0/1), handle binary/download (type 9/g/I), type-7 search.
- Multilevel history (back/forward). Adopt `agon-snail` scheme router for
  `home://` (built-in start page) and `file://` (local disk via `file.asm`).
- Milestone: browse multi-page gopherspace, back/forward, view text, save downloads.

**Phase 4 — NE2000 backend (rebuildable target)**
- Vendor RTL8019A libs; implement `backend_ne2000.asm` (resolve→open→send→recv).
- `make BACKEND=NE2000` produces a working `GOPHER.EXE` for the Ethernet card.
- Milestone: same browsing session works over NE2000 in MAME (pcap backend).

**Phase 5 — Polish & packaging**
- UTF-8 ↔ CP866 recode for content; status/title bars tuned for 80×32; error
  dialogs; config of home URL. Build both backends; FAT12 image; docs (HOWTO).
- Optional/deferred: AY music (`player/*`), image viewer (`screen-viewer/*`).

## 8. Risks & open questions

- **NE2000 TCP maturity:** that kit's `tcp_lib.asm` header still says
  "SEND/RECV/CLOSE TODO", but its `WGET` app calls them and is reported working.
  Validate `TCP.SEND/RECV/CLOSE` early in Phase 4; budget time to finish/patch if gaps.
- **Two different connect conventions** (ESP hostname-in-OPEN vs RTL resolve-first)
  — fully hidden by `NET.CONNECT`; keep the HAL the only place that differs.
- **80×32 layout redesign:** NEXTplorer UI was tuned for 80×25 tiles; rework
  header/status/scrollback for 32 rows of true text.
- **ISA/WIN3 discipline:** every net burst must `ISA_OPEN`…`ISA_CLOSE` with no
  DSS/BIOS calls in between; stack stays in WIN2. Highest-impact correctness rule.
- **Memory budget:** 64 KB window map; large page/download buffers via DSS `GetMem`.
- **Charset:** decide default recode on/off; gopher servers vary (UTF-8 vs CP866/ASCII).
- **Toolchain detail:** confirm `--raw` EXE output + header macro match the kits
  (reuse their `macro.inc` rather than hand-rolling the header).

## 9. References

See `CLAUDE.md` §9 for the full local path index (base clones, both net kits,
SpecTalkZX C reference, platform manual, DSS/BIOS sources).
