; ======================================================
; Console constants for the Moon Rabbit text UI (80x32, DSS).
; Extends the upstream dss.inc with the console function numbers and
; attribute/key codes this project uses. Numbers verified against
; Estex-DSS/DSS/API and the Sprinter text editor.
; ======================================================

	IFNDEF	_CONSOLE_INC
	DEFINE	_CONSOLE_INC

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

; --- screen geometry ---
SCR_W				EQU 80
SCR_H				EQU 32

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

	ENDIF
