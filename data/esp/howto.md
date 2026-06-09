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
| Esc / F10                 | quit (also cancels a running fetch/download)    |

The clock (top-right of the header) reads the Sprinter's CMOS time.

## Optional files next to GOPHER.EXE

- **`INDEX.GPH`** — your own home page in gopher-menu format. If present it
  overrides the built-in one; edit it however you like.

- **`GOPHER.CFG`** — settings and "open a downloaded file in a program"
  associations:

      [settings]
      skip_ask_for_exec = 0      ; 1/yes = open without asking, else ask

      [viewers]
      ; ext = program %file%   (%file% = absolute path of the saved file)
      scr = c:\utils\fview\fview.exe %file%
      gif = c:\bin\gifview.exe %file%

  When you download a file whose extension is listed, the browser offers to open
  it in the mapped program (`%file%` is replaced with the saved file's path).

## Downloads

Binary / media items (images, archives, disk images, …) are saved to a
`DOWNLOAD\` directory next to `GOPHER.EXE`. The browser never auto-opens them —
only through a `[viewers]` association above, on your confirmation.

## Notes

- The browser only opens TCP connections; joining Wi-Fi is done once by `NETUP`.
