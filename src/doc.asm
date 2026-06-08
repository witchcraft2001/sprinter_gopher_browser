; ======================================================
; DOC - paged gopher-document buffer (Phase 3 memory model, CLAUDE.md §4a).
;
; A document is stored as raw fetched bytes in a chain of up to DOC_MAX_PAGES
; GetMem 16 KB pages. The ISA window and a document page time-share WIN3
; (0xC000): never both at once.
;
; Page mapping: DSS GetMem (#3D) gives a block HANDLE; at alloc time BIOS EMM_FN5
; (#C5: A=handle, HL=dest → physical page bytes, #FF-terminated) resolves it into
; doc_phys[]. MAP_PAGE then maps a page with a single OUT (PAGE3=#E2), phys.
; RD_BYTE re-OUTs every byte (cheap), so a DSS/BIOS print that clobbers WIN3
; between bytes is harmless.
;
; Line addressing: SEEK_LINE is RELATIVE to a one-entry cache (sc_line + its
; page/offset) - it steps forward (SKIP_LINE) or backward (PREV_LINE) from the
; cached line, never re-scanning from the start. Consecutive seeks to nearby
; lines (the navigation pattern) are O(1). COUNT_LINES does one scan at load to
; get the total line count (for bounds). Position is (page,offset) - no 24-bit
; math. Cap DOC_MAX_PAGES (256 KB); beyond it the document is truncated.
; ======================================================

DOC_MAX_PAGES	EQU 16
DOC_PAGE_SIZE	EQU 0x4000
DOC_W3			EQU 0xC000

	MODULE DOC

; ---- state (lives in the WIN1 load image, mutated at runtime) ----
doc_blocks	DS DOC_MAX_PAGES, 0xFF	; GetMem block handle per logical page (0xFF=none)
doc_phys	DS DOC_MAX_PAGES, 0		; resolved physical page byte per logical page
doc_npages	DB 0					; pages allocated
doc_trunc	DB 0					; set if the document overflowed the cap
doc_wpage	DB 0					; current write page index
doc_woff	DW 0					; write offset within write page (0..0x4000)
doc_lines	DW 0					; total line count (set by COUNT_LINES)
doc_complete	DB 0				; 1 if COUNT_LINES saw the gopher "." terminator
doc_rpage	DB 0					; live read cursor page index
doc_roff	DW 0					; live read cursor offset within page
sc_line		DW 0					; seek cache: a known line number ...
sc_page		DB 0					; ... its page ...
sc_off		DW 0					; ... and offset (start of line sc_line)

; ------------------------------------------------------
; RESET - free every allocated page and clear all state.
; ------------------------------------------------------
RESET
	LD		A, (doc_npages)
	OR		A
	JR		Z, .cleared
	LD		B, A
	LD		HL, doc_blocks
.fl
	LD		A, (HL)
	CP		0xFF
	JR		Z, .skip
	PUSH	BC
	PUSH	HL
	LD		C, DSS_FREEMEM
	RST		DSS
	POP		HL
	POP		BC
.skip
	LD		(HL), 0xFF
	INC		HL
	DJNZ	.fl
.cleared
	XOR		A
	LD		(doc_npages), A
	LD		(doc_trunc), A
	LD		(doc_wpage), A
	LD		(doc_rpage), A
	LD		(sc_page), A
	LD		HL, 0
	LD		(doc_woff), HL
	LD		(doc_roff), HL
	LD		(doc_lines), HL
	LD		(sc_line), HL
	LD		(sc_off), HL
	RET

; The persistent part of the document = block handles, physical pages, and the
; metadata up to doc_complete (the read cursor / seek cache are transient). This
; whole block is saved/restored per history level so Back is instant (no refetch).
DOC_STATE_SIZE	EQU doc_complete + 1 - doc_blocks	; = 40

; ------------------------------------------------------
; SAVE_STATE - copy the live document state to (HL). Trashes BC, DE, HL.
; ------------------------------------------------------
SAVE_STATE
	EX		DE, HL					; DE = dest
	LD		HL, doc_blocks
	LD		BC, DOC_STATE_SIZE
	LDIR
	RET

; ------------------------------------------------------
; LOAD_STATE - restore the live document state from (HL), then reset the read
; cursor / seek cache so the next render re-seeks. Trashes BC, DE, HL.
; ------------------------------------------------------
LOAD_STATE
	LD		DE, doc_blocks
	LD		BC, DOC_STATE_SIZE
	LDIR
	XOR		A
	LD		(doc_rpage), A
	LD		(sc_page), A
	LD		HL, 0
	LD		(doc_roff), HL
	LD		(sc_line), HL
	LD		(sc_off), HL
	RET

; ------------------------------------------------------
; NEW - start a fresh empty document WITHOUT freeing the current pages (they were
; just SAVE_STATE'd into a history record and are owned there now). Marks every
; block slot empty so a later RESET won't double-free them.
; ------------------------------------------------------
NEW
	XOR		A
	LD		(doc_npages), A
	LD		(doc_trunc), A
	LD		(doc_wpage), A
	LD		(doc_rpage), A
	LD		(sc_page), A
	LD		(doc_complete), A
	LD		HL, 0
	LD		(doc_woff), HL
	LD		(doc_roff), HL
	LD		(doc_lines), HL
	LD		(sc_line), HL
	LD		(sc_off), HL
	LD		HL, doc_blocks
	LD		B, DOC_MAX_PAGES
.bl
	LD		(HL), 0xFF
	INC		HL
	DJNZ	.bl
	RET

; ------------------------------------------------------
; FREE_STATE - free the GetMem pages held by a SAVE_STATE'd descriptor at (HL)
; (used when evicting the oldest history level). Trashes regs.
; ------------------------------------------------------
FREE_STATE
	PUSH	HL
	LD		DE, doc_npages - doc_blocks
	ADD		HL, DE
	LD		A, (HL)					; npages from the saved descriptor
	POP		HL						; HL -> saved block handles
	OR		A
	RET		Z
	LD		B, A
.fl
	LD		A, (HL)
	CP		0xFF
	JR		Z, .skip
	PUSH	BC
	PUSH	HL
	LD		C, DSS_FREEMEM
	RST		DSS
	POP		HL
	POP		BC
.skip
	INC		HL
	DJNZ	.fl
	RET

; ------------------------------------------------------
; SIZE - document byte length. Out: HL = low 16 bits, A = high 8 bits
; (= doc_wpage*0x4000 + doc_woff). Trashes DE.
; ------------------------------------------------------
SIZE
	LD		HL, (doc_woff)
	LD		E, 0					; E = high-byte accumulator
	LD		A, (doc_wpage)
	LD		D, A					; D = page counter
.l
	LD		A, D
	OR		A
	JR		Z, .done
	LD		A, H
	ADD		A, 0x40					; += one 16 KB page (high byte 0x40)
	LD		H, A
	JR		NC, .nc
	INC		E
.nc
	DEC		D
	JR		.l
.done
	LD		A, E
	RET

; ------------------------------------------------------
; MAP_PAGE - map logical page A into WIN3 via OUT of its cached physical page to
; the PAGE3 MMU port (#E2). One OUT, no syscall. Preserves BC, DE, HL.
; ------------------------------------------------------
MAP_PAGE
	PUSH	BC
	PUSH	HL
	LD		HL, doc_phys
	ADD		A, L
	LD		L, A
	LD		A, 0
	ADC		A, H
	LD		H, A
	LD		A, (HL)					; physical page byte
	OUT		(PAGE3), A				; #E2 -> WIN3 maps this page
	POP		HL
	POP		BC
	RET

; ------------------------------------------------------
; APPEND - copy BC bytes from HL (WIN1/WIN2) into the document, growing the
; page chain on demand. Out: CF=0 (truncation is silent, sets doc_trunc).
; ------------------------------------------------------
APPEND
	LD		(.src), HL
	LD		(.len), BC
.loop
	LD		BC, (.len)
	LD		A, B
	OR		C
	JR		NZ, .cont
	OR		A						; CF=0, done
	RET
.cont
	LD		A, (doc_trunc)
	OR		A
	JR		NZ, .dropall
	LD		A, (doc_npages)
	OR		A
	JR		Z, .grow				; nothing allocated yet -> make the first page
	LD		HL, DOC_PAGE_SIZE
	LD		DE, (doc_woff)
	OR		A
	SBC		HL, DE					; HL = space left in current page
	LD		A, H
	OR		L
	JR		NZ, .haspace
.grow
	CALL	.new_page
	JR		C, .dropall
	LD		HL, DOC_PAGE_SIZE
.haspace
	LD		BC, (.len)
	PUSH	HL
	OR		A
	SBC		HL, BC					; space - len; CF=1 if space < len
	POP		HL
	JR		NC, .n_is_len
	LD		C, L					; n = space
	LD		B, H
	JR		.have_n
.n_is_len
	LD		BC, (.len)
.have_n
	LD		A, (doc_wpage)
	CALL	MAP_PAGE
	LD		HL, (doc_woff)
	LD		DE, DOC_W3
	ADD		HL, DE
	EX		DE, HL					; DE = dest in WIN3
	LD		HL, (.src)
	PUSH	BC
	LDIR
	POP		BC
	LD		(.src), HL
	LD		HL, (doc_woff)
	ADD		HL, BC
	LD		(doc_woff), HL
	LD		HL, (.len)
	OR		A
	SBC		HL, BC
	LD		(.len), HL
	JR		.loop
.dropall
	OR		A
	RET

.new_page
	LD		A, (doc_npages)
	CP		DOC_MAX_PAGES
	JR		NC, .np_fail
	LD		B, 1
	LD		C, DSS_GETMEM
	RST		DSS
	JR		C, .np_fail
	LD		D, A					; D = block handle
	CALL	.slot_addr				; HL = &doc_blocks[npages]
	LD		(HL), D
	CALL	.phys_addr				; HL = &doc_phys[npages]
	LD		A, D					; A = block handle
	LD		C, BIOS_EMM_FN5
	RST		BIOS
	JR		C, .np_freefail
	LD		A, (doc_npages)
	INC		A
	LD		(doc_npages), A
	DEC		A
	LD		(doc_wpage), A
	LD		HL, 0
	LD		(doc_woff), HL
	OR		A
	RET
.np_freefail
	CALL	.slot_addr
	LD		A, (HL)
	PUSH	HL
	LD		C, DSS_FREEMEM
	RST		DSS
	POP		HL
	LD		(HL), 0xFF
.np_fail
	LD		A, 1
	LD		(doc_trunc), A
	SCF
	RET
.slot_addr
	LD		HL, doc_blocks
	JR		.idx
.phys_addr
	LD		HL, doc_phys
.idx
	LD		A, (doc_npages)
	ADD		A, L
	LD		L, A
	LD		A, 0
	ADC		A, H
	LD		H, A
	RET
.src	DW 0
.len	DW 0

; ------------------------------------------------------
; AT_END - CF=1 if the read cursor has reached the write cursor (no more data).
; Preserves BC, DE, HL (callers keep pointers in HL across this). Trashes A.
; ------------------------------------------------------
AT_END
	PUSH	HL
	PUSH	DE
	LD		A, (doc_rpage)
	LD		HL, doc_wpage
	CP		(HL)
	JR		C, .more				; rpage < wpage
	JR		NZ, .end				; rpage > wpage
	LD		HL, (doc_roff)
	LD		DE, (doc_woff)
	OR		A
	SBC		HL, DE					; roff - woff; CF=1 if roff < woff
	JR		C, .more
.end
	POP		DE
	POP		HL
	SCF
	RET
.more
	POP		DE
	POP		HL
	OR		A
	RET

; ------------------------------------------------------
; RD_BYTE - read the byte at the read cursor, advance it. Out: A=byte.
; Re-maps the read page into WIN3 every call. Preserves BC, DE, HL.
; ------------------------------------------------------
RD_BYTE
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD		A, (doc_rpage)
	CALL	MAP_PAGE
	LD		HL, (doc_roff)
	LD		DE, DOC_W3
	ADD		HL, DE
	LD		A, (HL)
	LD		(.rb), A
	LD		HL, (doc_roff)
	INC		HL
	LD		(doc_roff), HL
	LD		A, H
	CP		0x40					; reached 0x4000 -> next page
	JR		NZ, .done
	LD		HL, 0
	LD		(doc_roff), HL
	LD		A, (doc_rpage)
	INC		A
	LD		(doc_rpage), A
.done
	POP		HL
	POP		DE
	POP		BC
	LD		A, (.rb)
	RET
.rb		DB 0

; ------------------------------------------------------
; Cursor +/- one byte (page-aware), and read-without-advance. Internal helpers
; for backward scanning. They mutate doc_rpage/doc_roff; trash A, HL.
; ------------------------------------------------------
INC_RPOS
	LD		HL, (doc_roff)
	INC		HL
	LD		A, H
	CP		0x40
	JR		NZ, .s
	LD		A, (doc_rpage)
	INC		A
	LD		(doc_rpage), A
	LD		HL, 0
.s
	LD		(doc_roff), HL
	RET

; cursor -= 1. CF=1 if it was already at (0,0).
DEC_RPOS
	LD		HL, (doc_roff)
	LD		A, H
	OR		L
	JR		NZ, .deco
	LD		A, (doc_rpage)
	OR		A
	JR		Z, .uf
	DEC		A
	LD		(doc_rpage), A
	LD		HL, 0x3FFF
	LD		(doc_roff), HL
	OR		A
	RET
.deco
	DEC		HL
	LD		(doc_roff), HL
	OR		A
	RET
.uf
	SCF
	RET

; read byte at cursor without advancing. A=byte. Trashes HL, DE.
RD_CUR
	LD		A, (doc_rpage)
	CALL	MAP_PAGE
	LD		HL, (doc_roff)
	LD		DE, DOC_W3
	ADD		HL, DE
	LD		A, (HL)
	RET

; ------------------------------------------------------
; PREV_LINE - move the read cursor from a line start back to the previous line
; start (no-op at the document start). Preserves BC, DE, HL.
; ------------------------------------------------------
PREV_LINE
	PUSH	BC
	PUSH	DE
	PUSH	HL
	CALL	.iszero					; at (0,0)?
	JR		Z, .ret
	CALL	DEC_RPOS				; -> cur-1 (LF terminating the previous line)
	CALL	.iszero
	JR		Z, .ret					; previous line is line 0 (starts at 0)
	CALL	DEC_RPOS				; -> cur-2
.scan
	CALL	.iszero
	JR		Z, .ret					; reached start -> line 0 start
	CALL	RD_CUR
	CP		10
	JR		Z, .lf
	CALL	DEC_RPOS
	JR		.scan
.lf
	CALL	INC_RPOS				; line starts right after the LF
.ret
	POP		HL
	POP		DE
	POP		BC
	RET
; ZF=1 if cursor == (page 0, offset 0). Trashes A, HL.
.iszero
	LD		HL, (doc_roff)
	LD		A, (doc_rpage)
	OR		H
	OR		L
	RET

; ------------------------------------------------------
; SEEK_LINE - position the read cursor at the start of line BC (0-based),
; relative to the seek cache (steps forward/backward from the nearest cached
; line; consecutive nearby seeks are O(1)). Updates the cache to line BC.
; ------------------------------------------------------
SEEK_LINE
	LD		A, (sc_page)
	LD		(doc_rpage), A
	LD		HL, (sc_off)
	LD		(doc_roff), HL
	LD		HL, BC
	LD		DE, (sc_line)
	OR		A
	SBC		HL, DE					; HL = n - sc_line
	JR		Z, .done
	JR		C, .back
.fwd
	LD		A, H
	OR		L
	JR		Z, .done
	CALL	SKIP_LINE
	DEC		HL
	JR		.fwd
.back
	LD		HL, (sc_line)
	OR		A
	SBC		HL, BC					; HL = sc_line - n (count back)
.bk
	LD		A, H
	OR		L
	JR		Z, .done
	CALL	PREV_LINE
	DEC		HL
	JR		.bk
.done
	LD		(sc_line), BC
	LD		A, (doc_rpage)
	LD		(sc_page), A
	LD		HL, (doc_roff)
	LD		(sc_off), HL
	RET

; advance the read cursor past one line (to the start of the next).
SKIP_LINE
.l
	CALL	AT_END
	RET		C
	CALL	RD_BYTE
	CP		10
	RET		Z
	JR		.l

; ------------------------------------------------------
; NEXT_LINE - copy the current line into LINE_BUF (NUL-terminated, CR stripped),
; advancing the read cursor past the LF.
; ------------------------------------------------------
NEXT_LINE
	LD		HL, MAIN.LINE_BUF
.l
	CALL	AT_END
	JR		C, .done
	CALL	RD_BYTE					; preserves HL
	CP		13
	JR		Z, .l					; drop CR
	CP		10
	JR		Z, .done				; LF ends the line (consumed)
	LD		(.sb), A
	PUSH	HL
	LD		DE, MAIN.LINE_BUF_END
	OR		A
	SBC		HL, DE					; CF=1 if HL < end (room)
	POP		HL
	JR		NC, .l					; no room -> drop, keep consuming
	LD		A, (.sb)
	LD		(HL), A
	INC		HL
	JR		.l
.done
	LD		(HL), 0
	RET
.sb		DB 0

; ------------------------------------------------------
; COUNT_LINES - one scan over the document to set doc_lines. Reads line by line
; (NEXT_LINE) and STOPS at the gopher "." terminator (a line that is exactly
; "."), so any trailing junk after it (stale page bytes / extra protocol bytes
; the kit may have delivered past the menu) is not counted or shown. Counts a
; trailing partial line with no terminating LF. Does not touch the seek cache.
; ------------------------------------------------------
COUNT_LINES
	XOR		A
	LD		(doc_rpage), A
	LD		(doc_complete), A		; assume incomplete until we meet "."
	LD		HL, 0
	LD		(doc_roff), HL
	LD		(doc_lines), HL
.l
	CALL	AT_END
	RET		C						; reached the end without a terminator (incomplete)
	CALL	NEXT_LINE				; -> MAIN.LINE_BUF (CR stripped, NUL-terminated)
	; gopher terminator? a line that is exactly "."
	LD		HL, MAIN.LINE_BUF
	LD		A, (HL)
	CP		'.'
	JR		NZ, .count
	INC		HL
	LD		A, (HL)
	OR		A
	JR		NZ, .count				; ".." etc. -> a real line, not the terminator
	LD		A, 1
	LD		(doc_complete), A		; LINE_BUF == "." -> document fully received
	RET
.count
	LD		HL, (doc_lines)
	INC		HL
	LD		(doc_lines), HL
	JR		.l

	ENDMODULE
