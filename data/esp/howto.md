# Gopher browser for Sprinter — quick start (ESP Wi-Fi)

A Gopher-protocol browser for the Sprinter, running under DSS in the native
80×32 text mode. Based on nihirash's Moon Rabbit / Internet NEXTplorer.

This build uses the **ESP Wi-Fi** network backend (SprinterWiFi, ESP8266 /
ESP-AT). For Wi-Fi it relies on the SprinterWiFi network kit.

## What you need

- A Sprinter with the **SprinterWiFi** Wi-Fi card.
- The **SprinterWiFi network kit** installed (it provides `NETUP` and `NET.CFG`).
- `GOPHER.EXE` (this program) on disk, e.g. in `C:\GOPHER\`.

## Quick start

1. **Configure Wi-Fi.** This is handled entirely by the SprinterWiFi network kit
   (its `NET.CFG`); see that package's documentation for how to set your network.

2. **Bring the link up** (once per session), before starting the browser:

       NETUP

   This joins Wi-Fi and publishes the link state so programs can open TCP.

3. **Run the browser:**

       GOPHER\GOPHER.EXE

   It opens on a built-in home page (no network needed) with a few starter
   links. Select one and press Enter to fetch it.

If the status line shows `Wi-Fi not up - run NETUP first`, repeat step 2.

## Keys

| Key                       | Action                                          |
|---------------------------|-------------------------------------------------|
| Up / Down, Home / End     | move the cursor / jump to start or end          |
| PgUp / PgDn (or Left/Right)| page up / down                                 |
| Enter                     | open the link / download a file / run a search  |
| Backspace                 | go back                                         |
| Ctrl+D                    | add the current page to bookmarks               |
| Ctrl+B                    | open bookmarks                                  |
| Esc / F10                 | quit (also cancels a running fetch/download)    |

The clock (top-right of the header) reads the Sprinter's CMOS time.

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

- The browser only opens TCP connections; joining Wi-Fi is done once by `NETUP`.
