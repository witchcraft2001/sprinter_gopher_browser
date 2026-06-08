; ======================================================
; Moon Rabbit - Gopher browser for Sprinter (DSS, 80x32 text)
; Base lineage: nihirash's Internet NEXTplorer (Z80) + agon-snail ideas.
;
; PHASE 3 - gopher engine (end-to-end browsing).
;   * Paged document buffer (src/doc.asm): fetched bytes live in a chain of
;     GetMem 16 KB pages, time-sharing WIN3 with the ISA window (CLAUDE.md §4a).
;     No 16 KB document limit; cap 16 pages (256 KB), then truncated.
;   * Gopher menus/text are parsed row-by-row (type/display/selector/host/port)
;     and rendered through the 30-row viewport directly from the doc pages.
;   * Enter follows a link (NET connect/send/recv into a fresh document);
;     Backspace goes back (history of navigation records, re-fetched on return);
;     Up/Down move, Left/Right page, Esc quits.
;   * Built-in "home" menu (WELCOME_DOC) is loaded at startup with no network,
;     so the browser is usable before the first fetch.
;   * Network errors are classified and shown on the status bar (no program
;     exit, no blocking "press a key"); NET.INIT runs once and is reused.
;
;   The WIN1 image holds all code + small state + stack (top 0x8000, down). A
;   GetMem page is mapped at WIN2 (0x8000) for the larger scratch buffers
;   (STAGE/LINE_BUF/REQ_BUF/HIST_DATA, see console.inc). Document pages and the
;   ISA window take turns in WIN3; we never SetWin2 over code because no code
;   lives in WIN2 (the proven wget layout).
; ======================================================

EXE_VERSION		EQU 1
LOAD_ADDR		EQU 0x4100
STACK_TOP		EQU 0x8000				; grows down through the WIN1 code page

DEFAULT_TIMEOUT	EQU 2000				; ms; also used by wcommon
RECV_TIMEOUT	EQU 5000				; ms per receive block

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"
	INCLUDE "console.inc"

	MODULE MAIN

; --- viewport layout ---
HEADER_ROW		EQU 0
VIEW_TOP		EQU 1
VIEW_ROWS		EQU 30
STATUS_ROW		EQU 31

; --- history ---
HIST_MAX		EQU 16
; history record field offsets (see HIST_DATA in console.inc)
HR_KIND			EQU 0					; 1: 0=home, 1=network
HR_HOST			EQU 1					; 64
HR_PORT			EQU 65					; 8
HR_SEL			EQU 73					; 200
HR_TYPE			EQU 273					; 1
HR_SELIDX		EQU 274					; 2
HR_TOPIDX		EQU 276					; 2
HR_TITLE		EQU 278					; 64 (page title shown in the header)
HR_SIZE			EQU 342
TITLE_MAX		EQU 64

	ORG LOAD_ADDR - 0x0200
EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0200
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 490, 0

	ORG LOAD_ADDR

START
	CALL	WCOMMON.INIT_VMODE			; record current mode so EXIT restores cleanly
	CALL	INIT_RUNTIME_PAGE			; map a fresh WIN2 page for the scratch buffers
	JP		C, MEM_ERROR
	CALL	DOC.RESET
	CALL	TERM.CLS
	CALL	LOAD_HOME				; sets DOC_TITLE before the header is drawn
	CALL	DRAW_HEADER
	LD		HL, 0
	LD		(sel_index), HL
	LD		(top_index), HL
	CALL	RENDER_VIEWPORT
	LD		HL, MSG_STATUS
	CALL	SET_STATUS

MAINLOOP
	CALL	KBD.SCAN
	JR		Z, MAINLOOP

	CP		KEY_ESC
	JP		Z, QUIT
	CP		KEY_ENTER
	JP		Z, ON_ENTER
	CP		KEY_BS
	JP		Z, ON_BACK

	LD		A, D
	CP		KEY_UP
	JP		Z, ON_UP
	CP		KEY_DOWN
	JP		Z, ON_DOWN
	CP		KEY_LEFT
	JP		Z, ON_PGUP
	CP		KEY_RIGHT
	JP		Z, ON_PGDN
	CP		KEY_PGUP
	JP		Z, ON_PGUP
	CP		KEY_PGDN
	JP		Z, ON_PGDN
	JR		MAINLOOP

QUIT
	LD		A, (net_inited)			; if we ever brought the ESP up, hand it back
	OR		A						; in command mode (socket closed) for the next program
	JR		Z, .noesp
	CALL	NET.SHUTDOWN
.noesp
	CALL	TERM.CLS				; leave a clean screen for the next program
	LD		D, 0
	LD		E, 0
	CALL	TERM.LOCATE
	LD		B, 0
	JP		WCOMMON.EXIT

MEM_ERROR
	PRINTLN	MSG_MEM_ERR
	LD		B, 3
	JP		WCOMMON.EXIT

; Allocate one 16 KB page and map it into WIN2 (0x8000) for the scratch buffers.
INIT_RUNTIME_PAGE
	LD		B, 1
	LD		C, DSS_GETMEM
	RST		DSS
	RET		C
	LD		B, 0
	LD		C, DSS_SETWIN2
	RST		DSS
	RET

; ------------------------------------------------------
; Navigation. An in-page Up/Down recolours only the two changed rows in place
; (cheap, no repaint). An Up/Down at a viewport edge, and PgUp/PgDn, full-redraw
; via RENDER_VIEWPORT (cheap now that SEEK_LINE is O(1)). We do NOT hardware-
; scroll: DSS Scroll #55 wedges on the full-width region (it hung the browser on
; long pages). Page jumps are blocked when the selection can't move (at top/end).
; ------------------------------------------------------
ON_UP
	LD		HL, (sel_index)
	LD		A, H
	OR		L
	JP		Z, MAINLOOP				; already at the top
	DEC		HL
	LD		(new_sel), HL			; new_sel = sel-1
	LD		DE, (top_index)
	OR		A
	SBC		HL, DE					; new_sel - top; CF=1 if new_sel < top
	JR		C, .scroll
	; still on screen: recolour old + new row only (cheap, no scroll)
	CALL	DEHILITE_OLD
	LD		HL, (new_sel)
	LD		(sel_index), HL
	CALL	HILITE_NEW
	JP		MAINLOOP
.scroll
	; cursor was on the top row: hardware-scroll the viewport down one line and
	; draw the newly exposed top row.
	CALL	DEHILITE_OLD
	LD		HL, (top_index)
	DEC		HL
	LD		(top_index), HL
	LD		HL, (new_sel)
	LD		(sel_index), HL
	LD		B, 2					; BIOS Lp_Scroll_Up: 2 = down
	CALL	SCROLL_VIEW
	LD		A, 0					; new selected row appears at slot 0
	CALL	DRAW_NEW_SEL_ROW
	JP		MAINLOOP

ON_DOWN
	LD		HL, (sel_index)
	INC		HL
	LD		DE, (DOC.doc_lines)
	PUSH	HL
	OR		A
	SBC		HL, DE					; (sel+1) - lines; CF=1 if still in range
	POP		HL
	JP		NC, MAINLOOP			; already at the last line
	LD		(new_sel), HL			; new_sel = sel+1
	; visible if new_sel < top + VIEW_ROWS
	LD		HL, (top_index)
	LD		DE, VIEW_ROWS
	ADD		HL, DE
	EX		DE, HL					; DE = top + VIEW_ROWS
	LD		HL, (new_sel)
	OR		A
	SBC		HL, DE					; new_sel - bottom; CF=1 if visible
	JR		C, .inpage
	; cursor ran off the bottom: hardware-scroll up one line, draw new bottom row
	CALL	DEHILITE_OLD
	LD		HL, (top_index)
	INC		HL
	LD		(top_index), HL
	LD		HL, (new_sel)
	LD		(sel_index), HL
	LD		B, 1					; BIOS Lp_Scroll_Up: 1 = up
	CALL	SCROLL_VIEW
	LD		A, VIEW_ROWS - 1		; new selected row appears at the bottom slot
	CALL	DRAW_NEW_SEL_ROW
	JP		MAINLOOP
.inpage
	CALL	DEHILITE_OLD
	LD		HL, (new_sel)
	LD		(sel_index), HL
	CALL	HILITE_NEW
	JP		MAINLOOP

; ---- incremental-render helpers ----
; De-highlight the row at the current sel_index (recolour to its natural attr,
; known from sel_type), leaving its text untouched.
DEHILITE_OLD
	LD		A, (sel_type)
	CALL	ATTR_FOR_TYPE
	PUSH	AF
	LD		HL, (sel_index)
	POP		AF
	JP		RECOLOR_ROW

; Highlight the row at the (just updated) sel_index, caching its gopher type.
HILITE_NEW
	LD		BC, (sel_index)
	CALL	GET_ROW_TYPE
	LD		(sel_type), A
	LD		HL, (sel_index)
	LD		A, ATTR_HILITE
	JP		RECOLOR_ROW

; Set the attribute of all SCR_W cells of the row showing line HL (no text
; rewrite). A = attribute. Uses BIOS Set_Place + Print_Atr (WIN2-resident stack).
RECOLOR_ROW
	PUSH	AF
	LD		DE, (top_index)
	OR		A
	SBC		HL, DE					; HL = slot (line - top)
	LD		A, L
	ADD		VIEW_TOP
	LD		D, A					; D = screen row
	LD		E, 0					; E = col
	LD		C, BIOS_SET_PLACE
	DI
	RST		BIOS
	POP		AF
	LD		E, A					; E = attribute
	LD		B, SCR_W
	LD		C, BIOS_PRINT_ATR
	RST		BIOS
	EI
	RET

; Hardware-scroll the 30-row viewport by one line. B = 1 (up) / 2 (down). Uses
; BIOS Lp_Scroll_Up (#8A): B=dir, D=begin-line, E=line-count (per BIOS docs and
; texteditor/SpecTalkZX). Interrupts OFF around it (the routine remaps VRAM and
; must not be interrupted) - this is what hung the DSS Scroll #55 path.
SCROLL_VIEW
	LD		D, VIEW_TOP				; begin line (0-based first viewport row)
	LD		E, VIEW_ROWS			; number of lines
	LD		C, BIOS_SCROLL			; #8A
	PUSH	IX
	DI
	RST		BIOS
	EI
	POP		IX
	RET

; Draw the selected row in full at slot A (a freshly scrolled-in row), highlighted,
; and cache its gopher type for the next de-highlight.
DRAW_NEW_SEL_ROW
	LD		(r_slot), A
	LD		A, 1
	LD		(r_sel_flag), A
	LD		BC, (sel_index)
	CALL	DRAW_ROW_LINE
	LD		A, (row_type)
	LD		(sel_type), A
	RET

; Draw the full row for line BC at slot r_slot with flag r_sel_flag.
DRAW_ROW_LINE
	CALL	DOC.SEEK_LINE
	CALL	DOC.AT_END
	JP		C, BLANK_ROW
	CALL	DOC.NEXT_LINE
	CALL	PARSE_ROW
	JP		DRAW_ROW

; A = natural (non-selected) attribute for gopher type A (in a menu). In a text
; document every line is normal.
ATTR_FOR_TYPE
	PUSH	AF
	LD		A, (DOC_TYPE_CUR)
	CP		'1'
	JR		Z, .menu
	POP		AF
	LD		A, ATTR_NORM
	RET
.menu
	POP		AF
	CP		'i'
	JR		Z, .norm
	CP		'.'
	JR		Z, .norm
	LD		A, ATTR_LINK
	RET
.norm
	LD		A, ATTR_NORM
	RET

; BC = line index -> A = gopher type byte ('i' if past the end of the document).
GET_ROW_TYPE
	CALL	DOC.SEEK_LINE
	CALL	DOC.AT_END
	LD		A, 'i'
	RET		C
	JP		DOC.RD_BYTE

ON_PGDN
	LD		DE, (DOC.doc_lines)
	LD		A, D
	OR		E
	JP		Z, MAINLOOP				; empty doc
	DEC		DE						; DE = lines-1 (clamp target)
	LD		HL, (sel_index)
	LD		BC, VIEW_ROWS
	ADD		HL, BC					; HL = sel + page
	PUSH	HL
	OR		A
	SBC		HL, DE					; target - (lines-1); CF=1 if target < lines-1
	POP		HL
	JR		C, .have
	EX		DE, HL					; clamp to lines-1
.have
	; HL = new selection. Skip the redraw if it did not move (already at the end).
	LD		DE, (sel_index)
	PUSH	HL
	OR		A
	SBC		HL, DE
	POP		HL
	JP		Z, MAINLOOP
	LD		(sel_index), HL
	JP		REDRAW

ON_PGUP
	LD		HL, (sel_index)
	LD		DE, VIEW_ROWS
	OR		A
	SBC		HL, DE
	JR		NC, .have
	LD		HL, 0
.have
	; HL = new selection. Skip the redraw if it did not move (already at the top).
	LD		DE, (sel_index)
	PUSH	HL
	OR		A
	SBC		HL, DE
	POP		HL
	JP		Z, MAINLOOP
	LD		(sel_index), HL
	JP		REDRAW

REDRAW
	CALL	RENDER_VIEWPORT
	JP		MAINLOOP

; Header + full viewport repaint (after a page change).
REDRAW_FULL
	CALL	DRAW_HEADER
	JP		RENDER_VIEWPORT

; Clamp sel_index into [0, doc_lines-1]; zero the view if the doc is empty.
CLAMP_SEL
	LD		HL, (DOC.doc_lines)
	LD		A, H
	OR		L
	JR		NZ, .nz
	LD		HL, 0
	LD		(sel_index), HL
	LD		(top_index), HL
	RET
.nz
	DEC		HL						; lines-1
	LD		DE, (sel_index)
	PUSH	HL
	OR		A
	SBC		HL, DE					; (lines-1) - sel; CF=1 if sel > lines-1
	POP		HL
	RET		NC
	LD		(sel_index), HL
	RET

; ------------------------------------------------------
; Enter: open the link on the selected row.
; ------------------------------------------------------
ON_ENTER
	LD		A, (DOC_TYPE_CUR)
	CP		'1'
	JP		NZ, MAINLOOP			; text document has no links
	LD		BC, (sel_index)
	CALL	DOC.SEEK_LINE
	LD		HL, (sel_index)
	LD		DE, (DOC.doc_lines)
	OR		A
	SBC		HL, DE
	JP		NC, MAINLOOP			; selection past end
	CALL	DOC.NEXT_LINE
	CALL	PARSE_ROW
	LD		A, (row_type)
	CP		'1'
	JR		Z, .follow
	CP		'0'
	JR		Z, .follow
	CP		'7'
	JP		Z, .unsupported			; search input - later phase
	CP		'i'
	JP		Z, MAINLOOP
	CP		'.'
	JP		Z, MAINLOOP
	JP		.unsupported			; binary/other types - later phase
.follow
	LD		HL, (p_host)
	LD		A, (HL)
	OR		A
	JP		Z, .unsupported			; no host on this row
	CALL	PUSH_HIST				; remember the page we are leaving (incl. its title)
	LD		HL, (p_disp)			; the clicked link's text becomes the new title
	LD		DE, DOC_TITLE
	LD		B, TITLE_MAX
	CALL	STRCPYN
	LD		HL, (p_host)
	LD		DE, HOST_CUR
	LD		B, 64
	CALL	STRCPYN
	LD		HL, (p_port)
	LD		DE, PORT_CUR
	LD		B, 8
	CALL	STRCPYN
	LD		HL, (p_sel)
	LD		DE, SEL_CUR
	LD		B, 200
	CALL	STRCPYN
	LD		A, (row_type)
	LD		(DOC_TYPE_CUR), A
	LD		A, 1
	LD		(cur_kind), A
	CALL	DO_FETCH
	JR		C, .ferr
	LD		HL, 0
	LD		(sel_index), HL
	LD		(top_index), HL
	CALL	REDRAW_FULL
	LD		HL, MSG_STATUS
	CALL	SET_STATUS
	JP		MAINLOOP
.ferr
	; fetch wiped the doc; revert the nav we just pushed and reload it
	CALL	POP_HIST
	CALL	NAV_RELOAD
	CALL	CLAMP_SEL
	CALL	REDRAW_FULL
	CALL	SHOW_ERROR
	JP		MAINLOOP
.unsupported
	LD		HL, MSG_UNSUPPORTED
	CALL	SET_STATUS
	JP		MAINLOOP

; ------------------------------------------------------
; Backspace: return to the previous page (re-fetch from its nav record).
; ------------------------------------------------------
ON_BACK
	LD		A, (hist_sp)
	OR		A
	JP		Z, MAINLOOP
	CALL	POP_HIST
	CALL	NAV_RELOAD
	CALL	CLAMP_SEL
	CALL	REDRAW_FULL
	LD		HL, MSG_STATUS
	CALL	SET_STATUS
	JP		MAINLOOP

; Reload the current nav (home page or network fetch). Returns CF on error.
NAV_RELOAD
	LD		A, (cur_kind)
	OR		A
	JP		Z, LOAD_HOME
	JP		DO_FETCH

; ------------------------------------------------------
; Built-in home page (no network). Loaded into the doc like any fetched page.
; ------------------------------------------------------
LOAD_HOME
	CALL	DOC.RESET
	XOR		A
	LD		(cur_kind), A
	LD		A, '1'
	LD		(DOC_TYPE_CUR), A
	LD		HL, MSG_TITLE			; default header title for the home page
	LD		DE, DOC_TITLE
	LD		B, TITLE_MAX
	CALL	STRCPYN
	LD		HL, 0
	LD		(HOST_CUR), HL			; empty host marks the home page
	LD		HL, WELCOME_DOC
	LD		BC, WELCOME_LEN
	CALL	DOC.APPEND
	CALL	DOC.COUNT_LINES
	OR		A
	RET

; ------------------------------------------------------
; Fetch HOST_CUR/SEL_CUR/PORT_CUR into a fresh document. CF=1 on error
; (message pointer left in last_err). NET.INIT runs once and is cached.
; ------------------------------------------------------
DO_FETCH
	CALL	DOC.RESET
	CALL	SHOW_FETCHING
	LD		A, (net_inited)
	OR		A
	JR		NZ, .haveinit
	CALL	NET.INIT
	JR		C, .e_init
	LD		A, 1
	LD		(net_inited), A
.haveinit
	LD		HL, HOST_CUR
	LD		DE, PORT_CUR
	CALL	NET.CONNECT
	JR		C, .e_conn
	CALL	BUILD_REQ				; HL=REQ_BUF, BC=len
	CALL	NET.SEND
	JR		C, .e_send
	CALL	RECV_LOOP				; appends every block into the document
	CALL	NET.CLOSE
	CALL	DOC.COUNT_LINES
	LD		HL, (DOC.doc_lines)
	LD		A, H
	OR		L
	JR		Z, .e_empty
	OR		A
	RET
.e_init
	LD		HL, ERR_INIT
	LD		(last_err), HL
	SCF
	RET
.e_conn
	CALL	NET.CLOSE
	LD		HL, ERR_CONN
	LD		(last_err), HL
	SCF
	RET
.e_send
	CALL	NET.CLOSE
	LD		HL, ERR_SEND
	LD		(last_err), HL
	SCF
	RET
.e_empty
	LD		HL, ERR_EMPTY
	LD		(last_err), HL
	SCF
	RET

; Receive blocks into STAGE and append to the document until the connection
; closes / times out, or the document hits its page cap.
; Receive into STAGE and append to the document. Brackets the slow append/redraw
; with RX pause (drops RTS so the ESP holds its TX → no UART FIFO overrun), and
; shows the running downloaded size on the status bar.
RECV_LOOP
	LD		HL, 0
	LD		(recv_lo), HL
	LD		(recv_hi), HL			; clears recv_hi (low byte) too
.l
	LD		A, (DOC.doc_trunc)
	OR		A
	JR		NZ, .end
	CALL	NET.RX_RESUME			; raise RTS: let the ESP stream
	LD		HL, STAGE
	LD		BC, STAGE_SIZE
	LD		DE, RECV_TIMEOUT
	CALL	NET.RECV
	PUSH	AF
	CALL	NET.RX_PAUSE			; drop RTS: ESP holds while we store + draw
	POP		AF
	JR		C, .end					; closed / timeout / error
	LD		A, B
	OR		C
	JR		Z, .end					; no more data
	PUSH	BC
	LD		HL, STAGE
	POP		BC
	PUSH	BC
	CALL	DOC.APPEND
	POP		BC
	; recv_total (24-bit) += BC
	LD		HL, (recv_lo)
	ADD		HL, BC
	LD		(recv_lo), HL
	JR		NC, .noc
	LD		A, (recv_hi)
	INC		A
	LD		(recv_hi), A
.noc
	CALL	SHOW_PROGRESS
	JR		.l
.end
	CALL	NET.RX_RESUME			; leave RX resumed for the CLOSE handshake
	RET

; Status-bar download progress: "Loading <n> bytes" (<1 KB) or "Loading <n> KB".
; Gopher has no content-length, so we show the downloaded amount, not a percent.
SHOW_PROGRESS
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
	LD		HL, MSG_LOADING
	CALL	TERM.PUTS
	; choose bytes vs KB
	LD		A, (recv_hi)
	OR		A
	JR		NZ, .kb					; >= 64 KB -> KB
	LD		HL, (recv_lo)
	LD		DE, 1024
	OR		A
	SBC		HL, DE					; lo - 1024; CF=1 if < 1 KB
	JR		NC, .kb
	LD		HL, (recv_lo)			; show raw bytes
	LD		DE, NUMBUF
	CALL	UTIL.UTOA
	LD		HL, SUFFIX_B
	JR		.draw
.kb
	; kb = (recv_hi << 6) + (recv_lo >> 10)
	LD		A, (recv_hi)
	LD		L, A
	LD		H, 0
	ADD		HL, HL
	ADD		HL, HL
	ADD		HL, HL
	ADD		HL, HL
	ADD		HL, HL
	ADD		HL, HL					; HL = recv_hi * 64
	LD		A, (recv_lo + 1)		; recv_lo >> 8
	SRL		A
	SRL		A						; >> 10 total (0..63)
	LD		E, A
	LD		D, 0
	ADD		HL, DE					; HL = KB
	LD		DE, NUMBUF
	CALL	UTIL.UTOA
	LD		HL, SUFFIX_KB
.draw
	LD		(prog_suffix), HL
	LD		HL, NUMBUF
	CALL	TERM.PUTS
	LD		HL, (prog_suffix)
	JP		TERM.PUTS

; Build the gopher request (SEL_CUR + CRLF) in REQ_BUF. Out: HL=REQ_BUF, BC=len.
BUILD_REQ
	LD		HL, SEL_CUR
	LD		DE, REQ_BUF
	CALL	COPYZ					; copies without the NUL; DE left at end
	LD		A, 13
	LD		(DE), A
	INC		DE
	LD		A, 10
	LD		(DE), A
	INC		DE
	LD		HL, REQ_BUF
	EX		DE, HL					; HL=end, DE=REQ_BUF
	OR		A
	SBC		HL, DE					; HL = length
	LD		B, H
	LD		C, L
	LD		HL, REQ_BUF
	RET

; ------------------------------------------------------
; Parse LINE_BUF into row_type + p_disp/p_sel/p_host/p_port (pointers into
; LINE_BUF). TABs are replaced with NUL; absent fields point at an empty string.
; ------------------------------------------------------
PARSE_ROW
	LD		DE, EMPTYSTR
	LD		(p_sel), DE
	LD		(p_host), DE
	LD		(p_port), DE
	LD		A, (DOC_TYPE_CUR)
	CP		'1'
	JR		Z, .menu
	; text document (type 0): the line is raw text, NO type byte and no TAB
	; fields - the whole line is the display.
	LD		HL, LINE_BUF
	LD		(p_disp), HL
	XOR		A
	LD		(row_type), A			; 0 = plain text line (non-selectable)
	RET
.menu
	LD		HL, LINE_BUF
	LD		A, (HL)
	LD		(row_type), A
	INC		HL
	LD		(p_disp), HL
	CALL	SCAN_FIELD				; end of display
	RET		NC						; info line: no further fields
	LD		(p_sel), HL
	CALL	SCAN_FIELD
	RET		NC
	LD		(p_host), HL
	CALL	SCAN_FIELD
	RET		NC
	LD		(p_port), HL
	RET

; Advance HL to the next field. If a TAB is found it is replaced with NUL and
; HL points past it (CF=1); at NUL, CF=0 (no more fields).
SCAN_FIELD
.l
	LD		A, (HL)
	OR		A
	JR		Z, .end
	CP		9
	JR		Z, .tab
	INC		HL
	JR		.l
.tab
	LD		(HL), 0
	INC		HL
	SCF
	RET
.end
	OR		A
	RET

; ------------------------------------------------------
; History: push current nav before following a link; pop to go back.
; ------------------------------------------------------
PUSH_HIST
	LD		A, (hist_sp)
	CP		HIST_MAX
	JR		C, .haveroom
	; full: drop the oldest record (shift the array down by one)
	LD		HL, HIST_DATA + HR_SIZE
	LD		DE, HIST_DATA
	LD		BC, (HIST_MAX - 1) * HR_SIZE
	LDIR
	LD		A, HIST_MAX - 1
	LD		(hist_sp), A
.haveroom
	LD		A, (hist_sp)
	CALL	HREC_ADDR				; HL = record address
	PUSH	HL
	LD		A, (cur_kind)
	LD		(HL), A					; +HR_KIND
	POP		HL
	PUSH	HL
	LD		DE, HR_HOST
	ADD		HL, DE
	EX		DE, HL
	LD		HL, HOST_CUR
	LD		B, 64
	CALL	STRCPYN
	POP		HL
	PUSH	HL
	LD		DE, HR_PORT
	ADD		HL, DE
	EX		DE, HL
	LD		HL, PORT_CUR
	LD		B, 8
	CALL	STRCPYN
	POP		HL
	PUSH	HL
	LD		DE, HR_SEL
	ADD		HL, DE
	EX		DE, HL
	LD		HL, SEL_CUR
	LD		B, 200
	CALL	STRCPYN
	POP		HL
	PUSH	HL
	LD		DE, HR_TYPE
	ADD		HL, DE
	LD		A, (DOC_TYPE_CUR)
	LD		(HL), A
	POP		HL
	PUSH	HL
	LD		DE, HR_SELIDX
	ADD		HL, DE
	EX		DE, HL
	LD		HL, (sel_index)
	CALL	STORE_HL_DE
	POP		HL
	LD		DE, HR_TOPIDX
	ADD		HL, DE
	EX		DE, HL
	LD		HL, (top_index)
	CALL	STORE_HL_DE
	; title
	LD		A, (hist_sp)
	CALL	HREC_ADDR
	LD		DE, HR_TITLE
	ADD		HL, DE
	EX		DE, HL
	LD		HL, DOC_TITLE
	LD		B, TITLE_MAX
	CALL	STRCPYN
	LD		A, (hist_sp)
	INC		A
	LD		(hist_sp), A
	RET

POP_HIST
	LD		A, (hist_sp)
	OR		A
	RET		Z
	DEC		A
	LD		(hist_sp), A
	CALL	HREC_ADDR				; HL = record
	PUSH	HL
	LD		A, (HL)
	LD		(cur_kind), A
	POP		HL
	PUSH	HL
	LD		DE, HR_HOST
	ADD		HL, DE
	LD		DE, HOST_CUR
	LD		B, 64
	CALL	STRCPYN
	POP		HL
	PUSH	HL
	LD		DE, HR_PORT
	ADD		HL, DE
	LD		DE, PORT_CUR
	LD		B, 8
	CALL	STRCPYN
	POP		HL
	PUSH	HL
	LD		DE, HR_SEL
	ADD		HL, DE
	LD		DE, SEL_CUR
	LD		B, 200
	CALL	STRCPYN
	POP		HL
	PUSH	HL
	LD		DE, HR_TYPE
	ADD		HL, DE
	LD		A, (HL)
	LD		(DOC_TYPE_CUR), A
	POP		HL
	PUSH	HL
	LD		DE, HR_SELIDX
	ADD		HL, DE
	CALL	LOAD_HL_FROM_HL
	LD		(sel_index), HL
	POP		HL
	PUSH	HL
	LD		DE, HR_TOPIDX
	ADD		HL, DE
	CALL	LOAD_HL_FROM_HL
	LD		(top_index), HL
	POP		HL
	LD		DE, HR_TITLE
	ADD		HL, DE
	LD		DE, DOC_TITLE
	LD		B, TITLE_MAX
	CALL	STRCPYN
	RET

; HL = HIST_DATA + A*HR_SIZE
HREC_ADDR
	LD		HL, HIST_DATA
	OR		A
	RET		Z
	LD		B, A
	LD		DE, HR_SIZE
.l
	ADD		HL, DE
	DJNZ	.l
	RET

; Store HL (16-bit little-endian) at (DE).
STORE_HL_DE
	LD		A, L
	LD		(DE), A
	INC		DE
	LD		A, H
	LD		(DE), A
	RET

; Load 16-bit little-endian from (HL) into HL.
LOAD_HL_FROM_HL
	LD		A, (HL)
	INC		HL
	LD		H, (HL)
	LD		L, A
	RET

; ------------------------------------------------------
; String helpers.
; ------------------------------------------------------
; Copy ASCIIZ HL->DE including the NUL, up to B-1 chars then forced NUL.
STRCPYN
.l
	LD		A, B
	CP		1
	JR		Z, .term
	LD		A, (HL)
	LD		(DE), A
	OR		A
	RET		Z
	INC		HL
	INC		DE
	DEC		B
	JR		.l
.term
	XOR		A
	LD		(DE), A
	RET

; Copy ASCIIZ HL->DE without the NUL. Out: DE past last char, HL past NUL.
COPYZ
.l
	LD		A, (HL)
	INC		HL
	OR		A
	RET		Z
	LD		(DE), A
	INC		DE
	JR		.l

; ------------------------------------------------------
; Status bar helpers.
; ------------------------------------------------------
; Fill the status row and print the ASCIIZ message in HL.
SET_STATUS
	PUSH	HL
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
	POP		HL
	JP		TERM.PUTS

SHOW_FETCHING
	LD		HL, MSG_FETCHING
	JP		SET_STATUS

SHOW_ERROR
	LD		HL, (last_err)
	JP		SET_STATUS

; ------------------------------------------------------
; Header bar.
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
	LD		HL, DOC_TITLE			; current page title (clicked link / home)
	JP		TERM.PUTS

; ------------------------------------------------------
; Viewport renderer (reads lines straight from the document pages).
; ------------------------------------------------------
RENDER_VIEWPORT
	CALL	ADJUST_VIEW
	LD		BC, (top_index)
	CALL	DOC.SEEK_LINE
	XOR		A
	LD		(r_slot), A
.loop
	LD		A, (r_slot)
	CP		VIEW_ROWS
	RET		Z
	; line index = top_index + r_slot
	LD		HL, (top_index)
	LD		A, (r_slot)
	LD		E, A
	LD		D, 0
	ADD		HL, DE					; HL = line index
	LD		DE, (DOC.doc_lines)
	PUSH	HL
	OR		A
	SBC		HL, DE					; line - lines; CF=1 if line < lines
	POP		HL
	JR		C, .have
	CALL	BLANK_ROW
	JR		.adv
.have
	; selected? compare line index (HL) with sel_index
	LD		DE, (sel_index)
	PUSH	HL
	OR		A
	SBC		HL, DE
	POP		HL
	LD		A, 0
	JR		NZ, .notsel
	INC		A						; A=1 selected
.notsel
	LD		(r_sel_flag), A
	CALL	DOC.NEXT_LINE
	CALL	PARSE_ROW
	LD		A, (r_sel_flag)			; cache the selected row's type for incremental moves
	OR		A
	JR		Z, .nocache
	LD		A, (row_type)
	LD		(sel_type), A
.nocache
	CALL	DRAW_ROW
.adv
	LD		HL, r_slot
	INC		(HL)
	JR		.loop

; Ensure top_index <= sel_index < top_index + VIEW_ROWS.
ADJUST_VIEW
	LD		HL, (sel_index)
	LD		DE, (top_index)
	PUSH	HL
	OR		A
	SBC		HL, DE					; sel - top; CF=1 if sel < top
	POP		HL
	JR		NC, .checkbottom
	LD		(top_index), HL			; top = sel
	RET
.checkbottom
	LD		HL, (top_index)
	LD		DE, VIEW_ROWS
	ADD		HL, DE					; top + VIEW_ROWS
	EX		DE, HL					; DE = top + VIEW_ROWS
	LD		HL, (sel_index)
	OR		A
	SBC		HL, DE					; sel - (top+VIEW_ROWS); CF=1 if in range
	RET		C
	LD		HL, (sel_index)
	LD		DE, VIEW_ROWS - 1
	OR		A
	SBC		HL, DE					; top = sel - VIEW_ROWS + 1
	LD		(top_index), HL
	RET

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

; Draw the parsed row at slot r_slot, highlighted if r_sel_flag. Menu rows get an
; icon + text at col 2; text-document lines are printed whole from col 1.
DRAW_ROW
	LD		A, (r_sel_flag)
	OR		A
	JR		NZ, .hi
	; not selected: text doc and info/'.' menu rows are plain; links are bright
	LD		A, (DOC_TYPE_CUR)
	CP		'1'
	JR		NZ, .norm				; text document -> normal attr
	LD		A, (row_type)
	CP		'i'
	JR		Z, .norm
	CP		'.'
	JR		Z, .norm
	LD		A, ATTR_LINK
	JR		.haveattr
.hi
	LD		A, ATTR_HILITE
	JR		.haveattr
.norm
	LD		A, ATTR_NORM
.haveattr
	LD		(r_attr), A
	; paint the row background (also sets the colour for following prints)
	LD		A, (r_slot)
	ADD		VIEW_TOP
	LD		D, A
	LD		E, 0
	LD		H, 1
	LD		L, SCR_W
	LD		A, (r_attr)
	LD		B, A
	LD		A, ' '
	CALL	TERM.FILL
	; text document: print the whole line from col 1 (no type byte / no icon)
	LD		A, (DOC_TYPE_CUR)
	CP		'1'
	JR		Z, .menu
	LD		A, (r_slot)
	ADD		VIEW_TOP
	LD		D, A
	LD		E, 1
	CALL	TERM.LOCATE
	CALL	CLIP_DISP
	LD		HL, (p_disp)
	JP		TERM.PUTS
.menu
	; menu row: icon + space + display text at column 2
	LD		A, (r_slot)
	ADD		VIEW_TOP
	LD		D, A
	LD		E, 2
	CALL	TERM.LOCATE
	LD		A, (row_type)
	CALL	GET_ICON
	CALL	TERM.PUTC
	LD		A, ' '
	CALL	TERM.PUTC
	CALL	CLIP_DISP
	LD		HL, (p_disp)
	JP		TERM.PUTS

; Truncate the display string so it fits the row (NUL at the cut point).
CLIP_DISP
	LD		HL, (p_disp)
	LD		B, SCR_W - 4
.l
	LD		A, (HL)
	OR		A
	RET		Z
	INC		HL
	DJNZ	.l
	LD		(HL), 0
	RET

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
	CP		'h'
	JR		Z, .link
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
.link
	LD		A, '@'
	RET
.info
	LD		A, ' '
	RET

; ------------------------------------------------------
; State (WIN1 load image).
; ------------------------------------------------------
sel_index		DW 0
top_index		DW 0
new_sel			DW 0					; pending selection during an incremental move
sel_type		DB 'i'					; gopher type of the selected row (for de-highlight)
r_slot			DB 0
r_attr			DB 0
r_sel_flag		DB 0
row_type		DB 0
p_disp			DW 0
p_sel			DW 0
p_host			DW 0
p_port			DW 0
hist_sp			DB 0
cur_kind		DB 0					; 0=home, 1=network
DOC_TYPE_CUR	DB '1'
net_inited		DB 0
last_err		DW 0
recv_lo			DW 0					; bytes received this fetch (low 16)
recv_hi			DB 0					; bytes received this fetch (high 8) -> 24-bit
prog_suffix		DW 0					; " bytes"/" KB" pointer during progress draw
NUMBUF			DS 8, 0					; UTIL.UTOA decimal scratch
EMPTYSTR		DB 0

HOST_CUR		DS 64, 0
PORT_CUR		DS 8, 0
SEL_CUR			DS 200, 0
; Current page title shown in the header (the display text of the link we
; followed; the home page sets a default). Saved/restored across history.
DOC_TITLE		DS TITLE_MAX, 0

; One decoded gopher row (type + TAB-split fields). MUST be in WIN1 (here in the
; code image), not the WIN2 scratch page: DSS PChars prints the display field
; straight from this buffer, and a WIN2 source prints as garbage.
LINE_BUF		DS 512, 0
LINE_BUF_END	EQU LINE_BUF + 510

; ------------------------------------------------------
; Text.
; ------------------------------------------------------
MSG_TITLE		DB "Moon Rabbit - gopher browser for Sprinter", 0
MSG_STATUS		DB "Up/Down move  PgUp/PgDn page  Enter open  Backspace back  Esc quit", 0
MSG_FETCHING	DB "Fetching...", 0
MSG_LOADING		DB "Loading ", 0
SUFFIX_B		DB " bytes", 0
SUFFIX_KB		DB " KB", 0
MSG_UNSUPPORTED	DB "That item type is not supported yet.", 0
MSG_MEM_ERR		DB "Cannot allocate work page.", 0
ERR_INIT		DB "Network init failed - run NETUP first.", 0
ERR_CONN		DB "Connect failed (check host / port / Wi-Fi).", 0
ERR_SEND		DB "Send failed.", 0
ERR_EMPTY		DB "No data received.", 0

; ------------------------------------------------------
; Built-in home page (gopher menu format; links are real network selectors).
; ------------------------------------------------------
WELCOME_DOC
	DB "iMoon Rabbit - a gopher browser for the Sprinter", 13, 10
	DB "i", 13, 10
	DB "iUp/Down move the cursor, Enter opens a link,", 13, 10
	DB "iLeft/Right page, Backspace goes back, Esc quits.", 13, 10
	DB "i", 13, 10
	DB "1Floodgap Systems gopher root", 9, 9, "gopher.floodgap.com", 9, "70", 13, 10
	DB "1About the Floodgap gopher", 9, "/gopher", 9, "gopher.floodgap.com", 9, "70", 13, 10
	DB "1SDF public access UNIX gopher", 9, 9, "sdf.org", 9, "70", 13, 10
	DB "i", 13, 10
	DB "iSelect a link above and press Enter to browse.", 13, 10
WELCOME_END
WELCOME_LEN		EQU WELCOME_END - WELCOME_DOC

	ENDMODULE

	INCLUDE "term.asm"
	INCLUDE "kbd.asm"
	INCLUDE "doc.asm"
	INCLUDE "net.asm"

	INCLUDE "netcfg_lib.asm"			; defines _NETCFG (needed by wcommon)
	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "esp_tcp.asm"
	INCLUDE "esplib.asm"				; anchors the lib BSS chain; keep last

	END MAIN.START
