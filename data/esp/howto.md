```
   ▄██████▄   ▄██████▄     ▄███████▄    ▄█    █▄       ▄████████    ▄████████ 
  ███    ███ ███    ███   ███    ███   ███    ███     ███    ███   ███    ███ 
  ███    █▀  ███    ███   ███    ███   ███    ███     ███    █▀    ███    ███ 
 ▄███        ███    ███   ███    ███  ▄███▄▄▄▄███▄▄  ▄███▄▄▄      ▄███▄▄▄▄██▀ 
▀▀███ ████▄  ███    ███ ▀█████████▀  ▀▀███▀▀▀▀███▀  ▀▀███▀▀▀     ▀▀███▀▀▀▀▀   
  ███    ███ ███    ███   ███          ███    ███     ███    █▄  ▀███████████ 
  ███    ███ ███    ███   ███          ███    ███     ███    ███   ███    ███ 
  ████████▀   ▀██████▀   ▄████▀        ███    █▀      ██████████   ███    ███ 
  Browser v.0.2.2                                                  ███    ███
```

# Gopher browser for Sprinter — quick start

A Gopher-protocol browser for the Sprinter, running under DSS in the native
80×32 text mode. Based on nihirash's Moon Rabbit / Internet NEXTplorer.

Author: Dmitry Mikhalchenkov, SprinterTeam. FidoNet: 2:5030/1997.10

The browser talks to the network through a small runtime-loaded UNETLD DLL,
so a single `GOPHER.EXE` can support any compatible Sprinter network card,
for example:

- **SprinterWiFi** (ESP8266 / ESP-AT) via `UNETESP.DLL`.
- **NE2000 / RTL8019A** ISA Ethernet via `UNETRTL.DLL`.
- **3Com 3C509B** ISA Ethernet via `UNET509B.DLL`.

The `NET` environment value published by a card's bring-up utility is mapped
to `UNET<TAG>.DLL`; `WIFI` is the compatibility alias for `UNETESP.DLL`.
Backends using the normal 3–4 character tag convention can be added beside
the executable without rebuilding `GOPHER.EXE`.

Which one is used is decided automatically, per session, by whichever network
kit you brought the link up with beforehand — the browser itself never talks
to the card directly.

## What you need

- A Sprinter with a **SprinterWiFi**, **NE2000/RTL8019A**, or **3Com 3C509B**
  card.
- The matching network kit installed:
  - Wi-Fi: the **SprinterWiFi network kit** (provides `NETUP` and `NET.CFG`).
  - RTL: the **sprinter-rtl8019a kit** (provides `NETCFG` and `IFUP`).
  - 3C509B: the **sprinter-3C509B kit** (provides `NETCFG` and `IFUP`).
- `GOPHER.EXE` together with the matching `UNET<TAG>.DLL` in the same
  directory, e.g. `C:\GOPHER\`. The standard distribution includes the
  currently manifest-listed backends.

## Quick start

1. **Bring exactly one link up before starting the browser** (once per
   session) — pick whichever card you have:

   - **Wi-Fi:** configure `NET.CFG` once (see the SprinterWiFi kit's own
     docs), then

         NETUP

   - **RTL8019A:** configure `NET.CFG` once (see the Sprinter RTL8019A kit's own
     docs), then

         NETCFG -i
         IFUP

   - **3Com 3C509B:** configure the card with the **sprinter-3C509B** kit,
     then

         NETCFG -i
         IFUP

   Either command publishes which backend is active; the browser reads that
   automatically the next time it needs the network — there is nothing to
   select inside the browser itself.

2. **Run the browser:**

       GOPHER\GOPHER.EXE

   It opens on a built-in home page (no network needed) with a few starter
   links. Select one and press Enter to fetch it.

If the status line shows `Network not configured`, repeat the bring-up step —
no network utility has published a link yet.

If a fetch instead shows `Network init failed`, check that the matching
`UNET<TAG>.DLL` is present next to `GOPHER.EXE`, that it implements the frozen
UNET ABI, and that the link is actually up.

## Keys

| Key                       | Action                                          |
|---------------------------|-------------------------------------------------|
| Up / Down, Home / End     | move the cursor / jump to start or end          |
| PgUp / PgDn (or Left/Right)| page up / down                                 |
| Enter                     | open the link / download a file / run a search  |
| Backspace                 | go back                                         |
| Ctrl+G                    | open `host[:port][/selector]`                   |
| Ctrl+D                    | add the current page to bookmarks               |
| Ctrl+B                    | open bookmarks                                  |
| Esc / F10                 | quit (also cancels a running fetch/download)    |

The header also shows the selected DLL (`DLL:UNETESP.DLL`, `DLL:UNETRTL.DLL`,
or `DLL:UNET509B.DLL`) before the clock. The clock (top-right) reads the
Sprinter's CMOS time.

**Ctrl+G** opens a gopher address directly. Enter `host`, `host:port`, or
`host[:port]/selector`; port 70 is the default and a bare host opens its root
menu. The selector is sent exactly as typed after the first slash, so use `//x`
when the selector itself begins with `/`.

## Bookmarks

- **Ctrl+D** — add the current page to bookmarks. Only works on network pages
  (the home page and the bookmarks list itself have no address, so there is
  nothing to bookmark). The browser appends a line to `BOOKMARK.GPH` next to
  `GOPHER.EXE` (creating it on the first bookmark).

- **Ctrl+B** — open the bookmarks list. It is shown as a normal gopher menu:
  move the cursor to an entry, Enter to follow it, Backspace to go back. If you
  have no bookmarks yet, a placeholder page with a hint is shown.

`BOOKMARK.GPH` is a plain text file in gopher-menu format (one bookmark per line:
`type<TAB>title<TAB>selector<TAB>host<TAB>port`); you can edit it by hand or copy
it to another Sprinter.

## Optional files next to GOPHER.EXE

- **`INDEX.GPH`** — your own home page in gopher-menu format. If present it
  overrides the built-in one; edit it however you like.

- **`BOOKMARK.GPH`** — the bookmarks file (created by Ctrl+D, opened by Ctrl+B).
  See the "Bookmarks" section above.

- **`UNET*.DLL`** — network backends. Keep the DLL whose tag matches the
  active `NET` value next to `GOPHER.EXE`; only that file is loaded.

- **`GOPHER.CFG`** — settings and program associations. Three sections:

      [settings]
      skip_ask_for_exec = 0      ; 1/yes = open without asking, else ask

      [viewers]
      ; ext = program %file%   (%file% = absolute path of the saved file)
      scr = c:\bin\zxview.exe %file%
      txt = c:\utils\fview\fview.exe %file%
      gif = c:\bin\gifview.exe %file%

      [urls]
      ; scheme = program %url%   (%url% = the full URL)
      http  = c:\net\wget.exe %url%
      ftp   = c:\net\ftp.exe %url%

  - **`[viewers]`** — which program opens a **downloaded file**, by its extension.
    When you download a file whose extension is listed, the browser offers to open
    it in the mapped program (`%file%` is replaced with the saved file's path).

  - **`[urls]`** — which program opens an **external-scheme link** (gopher type-`h`
    items, usually `URL:http://…`). For a matching scheme (`http`, `ftp`, …) the browser shows the URL and launches the mapped program
    (`%url%` is replaced with the full address). `gopher://` links are navigated by
    the browser itself and need no entry. If the scheme is not listed, the URL is
    just shown on the status line.

  Section, extension and scheme names are matched case-insensitively; the program
  path may be absolute or relative to the `GOPHER.EXE` directory. The launch
  confirmation can be turned off with `skip_ask_for_exec`.

## Downloads

Binary / media items (images, archives, disk images, …) are saved to a
`DOWNLOAD\` directory next to `GOPHER.EXE`. The browser never auto-opens them —
only through a `[viewers]` association above, on your confirmation.

## Notes

- The browser only opens TCP connections; bringing the link up is entirely the
  job of the network card's own utility, run once per session before the
  browser needs the network.
