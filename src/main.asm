; ======================================================
; Moon Rabbit - Gopher browser for Sprinter (DSS, 80x32 text)
; Base lineage: nihirash's Internet NEXTplorer (Z80) + agon-snail ideas.
;
; PHASE 1 - platform HAL + static gopher menu.
;   * TERM (text console) and KBD (keyboard) HAL over the DSS API.
;   * Renders a static gopher menu into an 80x32 viewport with a header and
;     status bar. Navigation is incremental: a same-page move only flips the
;     attribute of the two affected rows (BIOS Lp_Print_Atr, text untouched);
;     an edge step hardware-scrolls the viewport (BIOS Lp_Scroll_Up) and draws
;     just the newly exposed row.
;   * No hardware/network yet (Phase 2). See ../CLAUDE.md and ../plan.md.
; ======================================================

EXE_VERSION		EQU 1
STACK_TOP		EQU 0xBFFF

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"
	INCLUDE "console.inc"

	MODULE MAIN

; --- viewport layout ---
HEADER_ROW		EQU 0
VIEW_TOP		EQU 1					; first menu row (directly under header)
VIEW_ROWS		EQU 30					; rows 1..30
STATUS_ROW		EQU 31

	ORG 0x8080
EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100

START
	CALL	TERM.CLS
	CALL	DRAW_HEADER
	CALL	DRAW_STATUS
	CALL	RENDER_VIEWPORT

MAINLOOP
	CALL	KBD.SCAN
	JR		Z, MAINLOOP

	CP		KEY_ESC
	JR		Z, QUIT
	CP		KEY_ENTER
	JP		Z, ON_ENTER

	LD		A, D					; arrows arrive as positional codes
	CP		KEY_UP
	JR		Z, ON_UP
	CP		KEY_DOWN
	JR		Z, ON_DOWN
	CP		KEY_LEFT
	JR		Z, ON_PGUP
	CP		KEY_RIGHT
	JR		Z, ON_PGDN
	JR		MAINLOOP

QUIT
	LD		B, 0
	LD		C, DSS_EXIT
	RST		DSS

; ------------------------------------------------------
; Key handlers compute the desired selection index, then GO_SEL routes it.
; ------------------------------------------------------
ON_UP
	LD		A, (sel_index)
	AND		A
	JP		Z, MAINLOOP
	DEC		A
	JP		GO_SEL

ON_DOWN
	LD		A, (sel_index)
	INC		A
	CP		MENU_COUNT
	JP		NC, MAINLOOP
	JP		GO_SEL

ON_PGDN
	LD		A, (sel_index)
	ADD		VIEW_ROWS
	CP		MENU_COUNT
	JR		C, .store
	LD		A, MENU_COUNT - 1
.store
	JP		GO_SEL

ON_PGUP
	LD		A, (sel_index)
	SUB		VIEW_ROWS
	JR		NC, .store
	XOR		A
.store
	JP		GO_SEL

ON_ENTER
	CALL	SHOW_SELECTED
	JP		MAINLOOP

; ------------------------------------------------------
; Route a new selection (A) to the cheapest update path.
; ------------------------------------------------------
GO_SEL
	LD		B, A					; B = new selection
	LD		A, (sel_index)
	CP		B
	JP		Z, MAINLOOP				; unchanged

	LD		A, (top_index)
	CP		B
	JP		Z, GS_INVIEW			; new == top
	JP		C, GS_UPPER				; top < new

	LD		A, (top_index)			; new is above the viewport
	DEC		A
	CP		B
	JP		Z, GS_SCROLL_DOWN		; new == top-1 (single step up)
	JP		GS_REPOS

GS_UPPER
	LD		A, (top_index)
	ADD		VIEW_ROWS
	CP		B
	JP		Z, GS_SCROLL_UP			; new == top+VIEW_ROWS (single step down)
	JP		C, GS_REPOS				; new beyond viewport
GS_INVIEW
	LD		A, B
	CALL	MOVE_ONLY
	JP		MAINLOOP
GS_SCROLL_UP
	LD		A, B
	CALL	SCROLL_UP_ONE
	JP		MAINLOOP
GS_SCROLL_DOWN
	LD		A, B
	CALL	SCROLL_DOWN_ONE
	JP		MAINLOOP
GS_REPOS
	LD		A, B
	LD		(sel_index), A
	CALL	ADJUST_VIEW
	CALL	RENDER_VIEWPORT
	JP		MAINLOOP

; Selection stays on the visible page: just swap two row attributes.
MOVE_ONLY
	PUSH	AF
	LD		A, (sel_index)
	CALL	NORMAL_ROW
	POP		AF
	LD		(sel_index), A
	JP		HILITE_ROW

; Selection stepped one past the bottom: scroll up, expose new bottom row.
SCROLL_UP_ONE
	LD		(sel_index), A
	LD		B, 1
	CALL	SCROLL_REGION
	LD		HL, top_index
	INC		(HL)
	LD		A, (sel_index)
	DEC		A
	CALL	NORMAL_ROW
	LD		A, (sel_index)
	JP		RENDER_INDEX

; Selection stepped one past the top: scroll down, expose new top row.
SCROLL_DOWN_ONE
	LD		(sel_index), A
	LD		B, 2
	CALL	SCROLL_REGION
	LD		HL, top_index
	DEC		(HL)
	LD		A, (sel_index)
	INC		A
	CALL	NORMAL_ROW
	LD		A, (sel_index)
	JP		RENDER_INDEX

; In: B=1 up / 2 down. Scrolls the viewport region via DSS (#55).
; Raw BIOS #8A clobbers WIN2 (our code/stack); the DSS call is WIN2-safe.
SCROLL_REGION
	LD		D, VIEW_TOP
	LD		E, 0
	LD		H, VIEW_ROWS
	LD		L, SCR_W
	XOR		A					; A=0: blank the exposed line (we redraw it)
	LD		C, DSS_SCROLL
	RST		DSS
	RET

; Keep the selection inside the viewport (used by page jumps / reposition).
ADJUST_VIEW
	LD		A, (sel_index)
	LD		B, A
	LD		A, (top_index)
	CP		B
	JR		C, .check_bottom
	LD		A, B
	LD		(top_index), A
	RET
.check_bottom
	LD		A, (top_index)
	ADD		VIEW_ROWS
	LD		B, A
	LD		A, (sel_index)
	CP		B
	RET		C
	SUB		VIEW_ROWS - 1
	LD		(top_index), A
	RET

; ------------------------------------------------------
; Row attribute helpers (recolour without rewriting text).
; ------------------------------------------------------
; In: A=visible index. Sets the row to its de-selected (type-based) colour.
NORMAL_ROW
	PUSH	AF
	CALL	ENTRY_ADDR
	LD		A, (HL)
	CP		'i'
	LD		E, ATTR_LINK
	JR		NZ, .go
	LD		E, ATTR_NORM
.go
	POP		AF
	JP		SET_ROW_ATTR

; In: A=visible index. Highlights the row.
HILITE_ROW
	LD		E, ATTR_HILITE
	; fall through

; In: A=visible index, E=attr. Recolours the whole row.
SET_ROW_ATTR
	LD		C, E					; save attr
	LD		HL, top_index
	SUB		(HL)
	ADD		VIEW_TOP
	LD		D, A					; D = row
	LD		E, 0					; E = col 0
	PUSH	BC						; save attr (in C)
	LD		C, BIOS_SET_PLACE
	DI
	RST		BIOS
	POP		BC						; C = attr
	LD		E, C					; E = attr
	LD		B, SCR_W				; B = cell count
	LD		C, BIOS_PRINT_ATR
	RST		BIOS
	EI
	RET

; ------------------------------------------------------
; Header / status bars
; ------------------------------------------------------
DRAW_HEADER
	LD		D, HEADER_ROW
	LD		E, 0
	LD		H, 1
	LD		L, SCR_W
	LD		B, ATTR_HEADER
	LD		A, ' '
	CALL	TERM.FILL
	LD		D, HEADER_ROW
	LD		E, 1
	CALL	TERM.LOCATE
	LD		HL, MSG_TITLE
	JP		TERM.PUTS

DRAW_STATUS
	LD		D, STATUS_ROW
	LD		E, 0
	LD		H, 1
	LD		L, SCR_W
	LD		B, ATTR_STATUS
	LD		A, ' '
	CALL	TERM.FILL
	LD		D, STATUS_ROW
	LD		E, 1
	CALL	TERM.LOCATE
	LD		HL, MSG_STATUS
	JP		TERM.PUTS

; Echo the selected entry's text on the status line (stand-in for "open").
SHOW_SELECTED
	LD		D, STATUS_ROW
	LD		E, 0
	LD		H, 1
	LD		L, SCR_W
	LD		B, ATTR_HILITE
	LD		A, ' '
	CALL	TERM.FILL
	LD		D, STATUS_ROW
	LD		E, 1
	CALL	TERM.LOCATE
	LD		HL, MSG_OPEN
	CALL	TERM.PUTS
	LD		A, (sel_index)
	CALL	ENTRY_ADDR
	INC		HL
	JP		TERM.PUTS

; ------------------------------------------------------
; Viewport renderer
; ------------------------------------------------------
RENDER_VIEWPORT
	XOR		A
	LD		(r_slot), A
	LD		A, (top_index)
	LD		(r_idx), A
.loop
	LD		A, (r_slot)
	CP		VIEW_ROWS
	RET		Z
	LD		A, (r_idx)
	CP		MENU_COUNT
	JR		C, .have
	CALL	BLANK_ROW
	JR		.adv
.have
	CALL	RENDER_ENTRY
.adv
	LD		HL, r_slot
	INC		(HL)
	LD		HL, r_idx
	INC		(HL)
	JR		.loop

BLANK_ROW
	LD		A, (r_slot)
	ADD		VIEW_TOP
	LD		D, A
	LD		E, 0
	LD		H, 1
	LD		L, SCR_W
	LD		B, ATTR_NORM
	LD		A, ' '
	JP		TERM.FILL

; In: A=visible index. Renders that one entry's row in full.
RENDER_INDEX
	LD		(r_idx), A
	LD		HL, top_index
	SUB		(HL)
	LD		(r_slot), A
	; fall through

RENDER_ENTRY
	LD		A, (r_slot)
	ADD		VIEW_TOP
	LD		(r_row), A

	LD		A, (r_idx)
	CALL	ENTRY_ADDR
	LD		A, (HL)
	LD		(r_type), A
	INC		HL
	LD		(r_textptr), HL

	; pick attribute: selected > info > link
	LD		A, (r_idx)
	LD		B, A
	LD		A, (sel_index)
	CP		B
	JR		Z, .a_sel
	LD		A, (r_type)
	CP		'i'
	JR		Z, .a_info
	LD		A, ATTR_LINK
	JR		.a_set
.a_info
	LD		A, ATTR_NORM
	JR		.a_set
.a_sel
	LD		A, ATTR_HILITE
.a_set
	LD		(r_attr), A

	LD		A, (r_row)
	LD		D, A
	LD		E, 0
	LD		H, 1
	LD		L, SCR_W
	LD		A, (r_attr)
	LD		B, A
	LD		A, ' '
	CALL	TERM.FILL

	LD		A, (r_row)
	LD		D, A
	LD		E, 2
	CALL	TERM.LOCATE

	LD		A, (r_type)
	CALL	GET_ICON
	CALL	TERM.PUTC
	LD		A, ' '
	CALL	TERM.PUTC
	LD		HL, (r_textptr)
	JP		TERM.PUTS

; In: A=gopher type char. Out: A=icon character.
GET_ICON
	CP		'1'
	JR		Z, .dir
	CP		'0'
	JR		Z, .txt
	CP		'7'
	JR		Z, .search
	CP		'9'
	JR		Z, .bin
	CP		'I'
	JR		Z, .bin
	CP		'g'
	JR		Z, .bin
	CP		'i'
	JR		Z, .info
	LD		A, ' '
	RET
.dir
	LD		A, '/'
	RET
.txt
	LD		A, '='
	RET
.search
	LD		A, '?'
	RET
.bin
	LD		A, '*'
	RET
.info
	LD		A, ' '
	RET

; In: A=entry index. Out: HL -> entry (type byte). No DSS/BIOS calls.
ENTRY_ADDR
	LD		HL, menu_start
	AND		A
	RET		Z
	LD		B, A
.next
	INC		HL						; skip type
.txt
	LD		A, (HL)
	INC		HL
	OR		A
	JR		NZ, .txt				; skip text incl. terminator
	DJNZ	.next
	RET

	INCLUDE "term.asm"
	INCLUDE "kbd.asm"

; ------------------------------------------------------
; State
; ------------------------------------------------------
sel_index	DB 0
top_index	DB 0
r_slot		DB 0
r_idx		DB 0
r_row		DB 0
r_type		DB 0
r_attr		DB 0
r_textptr	DW 0

; ------------------------------------------------------
; Text
; ------------------------------------------------------
MSG_TITLE	DB "Moon Rabbit  -  gopher://gopher.floodgap.com/", 0
MSG_STATUS	DB "Up/Down: move   Left/Right: page   Enter: open   Esc: quit", 0
MSG_OPEN	DB "Open: ", 0

; ------------------------------------------------------
; Static gopher menu: each entry = type byte + ASCIIZ display text.
; ------------------------------------------------------
menu_start
	DB '1' : DZ "Floodgap Systems gopher root"
	DB 'i' : DB 0
	DB 'i' : DZ "Welcome to gopherspace!"
	DB 'i' : DZ "----------------------------------------"
	DB '1' : DZ "About Floodgap"
	DB '1' : DZ "Floodgap Gopher Search Engine (Veronica-2)"
	DB '7' : DZ "Search Veronica-2"
	DB '0' : DZ "What is Gopher? (text)"
	DB '1' : DZ "News and Updates"
	DB '1' : DZ "Software Archive"
	DB '9' : DZ "gopherproxy.tgz (download)"
	DB 'I' : DZ "screenshot.gif (image)"
	DB '0' : DZ "README.txt"
	DB '1' : DZ "Fun and Games"
	DB '1' : DZ "Weather"
	DB '0' : DZ "Today's forecast"
	DB '1' : DZ "Gopher Clients"
	DB '1' : DZ "Other Gopher Servers"
	DB '1' : DZ "SDF Public Access UNIX"
	DB '1' : DZ "Quux.org"
	DB 'i' : DZ "----------------------------------------"
	DB '1' : DZ "Personal phlogs"
	DB '1' : DZ "zaibatsu.circumlunar.space"
	DB '1' : DZ "republic.circumlunar.space"
	DB '0' : DZ "phlog: a day in the life"
	DB '1' : DZ "Mirrors"
	DB '1' : DZ "Project Gutenberg (mirror)"
	DB '0' : DZ "gopher: history and culture"
	DB '1' : DZ "Retrocomputing"
	DB '1' : DZ "ZX Spectrum corner"
	DB '0' : DZ "Sprinter notes"
	DB '1' : DZ "Bottom of the menu"
	DB 'i' : DZ "----------------------------------------"
	DB 'i' : DZ "End of list. Press Esc to quit."

MENU_COUNT	EQU 34

	ENDMODULE
