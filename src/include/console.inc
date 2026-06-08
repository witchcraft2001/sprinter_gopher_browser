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
DSS_APPINFO			EQU 0x47
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

; --- screen geometry ---
SCR_W				EQU 80
SCR_H				EQU 32

; --- WIN2 scratch layout (inside the GetMem page mapped at 0x8000) ---
; Stack lives in WIN1 (top 0x8000, growing down), so the whole 0x8000..0xBFFF
; WIN2 page is free for these runtime buffers. Plain EQUs so MAIN and DOC share.
WIN2_BASE			EQU 0x8000
STAGE				EQU 0x8000			; TCP receive staging buffer
STAGE_SIZE			EQU 2048
REQ_BUF				EQU 0x8A00			; outgoing selector + CRLF
HIST_DATA			EQU 0x8C00			; history record array (ends ~0x9D60)
; LINE_BUF lives in WIN1 (the code image), NOT this WIN2 page: DSS PChars prints
; a row from it, and printing a source string out of the WIN2 page renders
; garbage (header/status print fine from WIN1). Defined as MAIN.LINE_BUF.

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

	ENDIF
