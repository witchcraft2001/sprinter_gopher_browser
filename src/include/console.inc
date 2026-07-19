; ======================================================
; Console constants for the Moon Rabbit text UI (80x32, DSS).
; Extends the upstream dss.inc with the console function numbers and
; attribute/key codes this project uses. Numbers verified against
; Estex-DSS/DSS/API and the Sprinter text editor.
; ======================================================

	IFNDEF	_CONSOLE_INC
	DEFINE	_CONSOLE_INC

; --- DSS application info (C=#47; B selects: 0=cmdline params, 1=EXE home dir
;     (path up to & incl. the last '\'), 2=EXE full path+name). DE=dest buffer. ---
APPINFO_DIR			EQU 1				; B=1: directory containing the EXE
APPINFO_FULLPATH	EQU 2				; B=2: full path + filename of the EXE

; --- DSS console functions (C before RST #10) ---
DSS_LOCATE			EQU 0x52			; D=row E=col (0-based)
DSS_CURSOR			EQU 0x53			; -> D=row E=col
DSS_SCROLL			EQU 0x55			; D,E top-left H,L size B=1 up/2 down A=fill flag
DSS_WRCHAR			EQU 0x58			; D=row E=col A=char B=attr

; --- BIOS functions (C before RST #08) used for fast row updates ---
BIOS				EQU 0x08
BIOS_PRINT_ATR		EQU 0x83			; D=row E=... set attr of B cells at cursor: B=count E=attr
BIOS_SET_PLACE		EQU 0x84			; D=row E=col
BIOS_SCROLL			EQU 0x8A			; B=1 up/2 down D=height E=top-row (full width)
BIOS_EMM_FN5		EQU 0xC5			; A=block_id HL=dest -> writes the block's physical page
									; bytes (one per page), #FF-terminated, B=count. Then a
									; raw OUT of a page byte to a PAGEx port maps it (no DSS
									; SetWin3 dispatch). Proven by the DSS CD driver (CDX) and
									; the spevosdk loader on MAME / real hardware.

; --- direct text VRAM (fast path, no DSS/BIOS call) ---
; Map VRAM page #50 into WIN3 (OUT (PAGE3)); PORT_Y (#89, write-only) selects
; the text COLUMN (value = col+1 for screen A); the symbol byte of (col,row) is
; then at #C301+row*4, its attribute at #C302+row*4. Park PORT_Y at #C0 after.
PORT_Y				EQU 0x89
VRAM_TXT_PAGE		EQU 0x50
VRAM_PORTY_PARK		EQU 0xC0

; --- screen geometry ---
SCR_W				EQU 80
SCR_H				EQU 32

; --- WIN2 scratch layout (inside the GetMem page mapped at 0x8000) ---
; Stack lives in WIN1 (top 0x8000, growing down), so the whole 0x8000..0xBFFF
; WIN2 page is free for these runtime buffers. Plain EQUs so MAIN and DOC share.
WIN2_BASE			EQU 0x8000
STAGE				EQU 0x8000			; DSS file/config streaming buffer
STAGE_SIZE			EQU 2048
BM_LINE				EQU 0x8800			; bookmark record builder (352 B; ends 0x895F)
; Download target address, runtime-written per download (frees WIN1 image
; space; the network-lib BSS must stay below 0x8000).
DL_HOST				EQU 0x8960			; 64 B (ends 0x899F)
DL_PORT				EQU 0x89A0			; 8 B (ends 0x89A7; 0x89A8..0x89FF spare)
REQ_BUF				EQU 0x8A00			; outgoing selector + CRLF
HIST_DATA			EQU 0x8C00			; history record array (ends ~0x97F0)
; GOPHER.CFG is streamed through STAGE; its line accumulator lives up here in the
; WIN2 scratch page (code is in WIN1 so it can never reach this). Only [settings]
; are kept (a tiny WIN1 pool); ext->program lookups re-scan the file on demand.
CFG_LINE			EQU 0x9800			; config line accumulator (256 B; ends 0x98FF)
; DL_SEL overlays CFG_LINE: the config accumulator runs at startup (CFG.LOAD)
; and during post-download / URL-launch lookups (VIEWER_FOR_EXT etc.), never
; inside the download flow that owns DL_SEL. 200 B <= 256 B.
DL_SEL				EQU CFG_LINE
; Path/exec buffers kept in WIN2 (not WIN1) so they don't eat the tight stack
; headroom below 0x8000. Never PChars sources - only DSS file/exec args + Z80 ops.
EXE_DIR				EQU 0x9900			; AppInfo #47 EXE home dir (256 B)
FILE_ABS			EQU 0x9A00			; absolute saved-file path for %file% (160 B)
CFG_ST_POOL			EQU 0x9AA0			; kept [settings] strings (256 B)
CFG_CMD_BUF			EQU 0x9BA0			; built Dss.Exec command line (192 B)
HOST_CUR			EQU 0x9C60			; current page host (64 B)   - fetch nav buffers
PORT_CUR			EQU 0x9CA0			; current page port (8 B)      (not PChars sources)
SEL_CUR				EQU 0x9CA8			; current page selector (200 B; ends 0x9D70)
; Parsed/rendered row. PChars has been verified with WIN2 sources; keeping this
; 512-byte buffer here frees scarce WIN1 image space for streaming logic.
LINE_BUF			EQU 0x9D80			; 512 B; ends 0x9F7F
; Download target name/path. Runtime-written (MAKE_DLNAME) before every
; download; live here instead of the WIN1 image to keep the network-lib BSS
; below 0x8000. Read by FILE.* (DSS args) and SHOW_SAVED (PChars-safe).
DL_NAME				EQU 0x9F80			; 16 B: derived 8.3 filename
DL_PATH				EQU 0x9F90			; 32 B: "DOWNLOAD\<name>" (ends 0x9FAF)
; Web-link status string (type-h URLs with no [urls] handler). Runtime-written,
; PChars'd from WIN2 (verified safe); disjoint from any download. Fills the gap
; between DL_PATH and DL_BUF (0x9FB0..0x9FFF = 80 B).
WEBLINK_BUF			EQU 0x9FB0			; 80 B (ends 0x9FFF)
; Shared network accumulator. Page fetches append it to DOC; binary downloads
; fill it completely, then flush every complete 512-byte sector to FAT in one
; maximal (4 KB) write, keeping the sub-sector remainder for the next round.
; It also overlays NETCFG BSS, whose lifetime ends before either transfer.
; Sits above the small buffers and below the stack (0xA000..0xAFFF); never a
; PChars source (raw bytes only).
DL_BUF				EQU 0xA000			; 4 KB download buffer (ends 0xAFFF)
DL_BUF_SIZE			EQU 0x1000			; 4096
; Runtime stack: the top 4 KB of our WIN2 GetMem page (0xB000..0xBFFF, top
; 0xC000, grows down). The code image fits entirely in WIN1 (< 16 KB), so the
; whole WIN2 page is ours and the stack lives here - far from the network lib's
; BSS (which sits just under 0x8000 in WIN1). This replaces the old "stack in
; WIN1 under the BSS" model whose ~1.8 KB margin overflowed into the BSS during a
; deep receive + clock draw ("Network init failed"). START switches SP here once
; the page is mapped; it survives Dss.Exec unchanged (DSS saves/restores the
; parent's window registers, and this GetMem page is tagged to our task so the
; child can't allocate over it). 0xB000 > DL_BUF end (0xAFFF).
RUN_STACK_TOP		EQU 0xC000
; LINE_BUF is also in this WIN2 page. DSS PChars prints correctly from WIN2
; (verified on target); a row is copied out only so a doc page need not remain
; mapped in WIN3 across the print call.

; --- attribute byte: PAPER(hi nibble, 0..7) | INK(lo nibble, 0..15) ---
ATTR_NORM			EQU 0x07			; light grey on black (info text)
ATTR_LINK			EQU 0x0F			; white on black (selectable items)
ATTR_HILITE			EQU 0x70			; black on light grey (selected row)
ATTR_HEADER			EQU 0x1F			; white on blue
ATTR_STATUS			EQU 0x1F			; white on blue

; --- key codes (A=char code, D=positional code from ScanKey/WaitKey) ---
KEY_ENTER			EQU 0x0D			; in A
KEY_ESC				EQU 0x1B			; in A
KEY_BS				EQU 0x08			; in A
KEY_UP				EQU 0x58			; in D
KEY_DOWN			EQU 0x52			; in D
KEY_LEFT			EQU 0x54			; in D
KEY_RIGHT			EQU 0x56			; in D
KEY_PGUP			EQU 0x59			; in D
KEY_PGDN			EQU 0x53			; in D
KEY_HOME			EQU 0x57			; in D
KEY_END				EQU 0x51			; in D
KEY_F10				EQU 0x44			; in D (DSS XLAT: F1=#3B..F12=#46)
; Physical keycodes for letter keys (in D). With Ctrl held the symbolic code
; (A/E) is 0, so a Ctrl+letter shortcut is recognised by the letter's D code.
; Values are the DSS XLAT_T outputs for the B/D keys (AT set-2 0x32/0x23);
; verified against KEYINTER.ASM and the texteditor's Ctrl+Y/C/V/X codes.
KEY_B				EQU 0x2E			; in D (B key)
KEY_D				EQU 0x1F			; in D (D key)

	ENDIF
