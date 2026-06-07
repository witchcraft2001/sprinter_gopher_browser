; ======================================================
; DOC - paged gopher-document buffer (Phase 3 memory model, CLAUDE.md §4a).
;
; A document is stored as raw fetched bytes in a chain of up to DOC_MAX_PAGES
; GetMem 16 KB pages. The ISA window and a document page time-share WIN3
; (0xC000): never both at once.
;
; Page mapping: DSS GetMem (#3D) returns a block HANDLE, not a physical page.
; At alloc time we resolve the block's physical page numbers via BIOS EMM_FN5
; (#C5: A=handle, HL=dest -> writes phys page bytes, #FF-terminated, B=count) and
; cache them in doc_phys[]. Mapping a page into WIN3 is then a single
; `OUT (PAGE3=#E2), phys` (MAP_PAGE) - no per-switch DSS dispatch. This is the
; loader/CD-driver idiom, proven on MAME and real hardware.
;
; The reader walks bytes sequentially, re-mapping WIN3 on every RD_BYTE (the OUT
; is cheap), so a TERM/DSS/BIOS print between bytes that clobbers WIN3 is
; harmless. Each visible line is still copied into LINE_BUF (WIN2) before any
; DSS/BIOS call. Position is (page index, offset 0..0x4000) - no 24-bit math.
; Cap is DOC_MAX_PAGES (256 KB); past that the document is truncated (doc_trunc).
; ======================================================

DOC_MAX_PAGES	EQU 16
DOC_PAGE_SIZE	EQU 0x4000
DOC_W3			EQU 0xC000

	MODULE DOC

; ---- state (lives in the WIN1 load image, mutated at runtime) ----
doc_blocks	DS DOC_MAX_PAGES, 0xFF	; GetMem block handle per logical page (0xFF=none, for FreeMem)
doc_phys	DS DOC_MAX_PAGES, 0		; resolved physical page byte per logical page (-> PAGE3)
doc_npages	DB 0					; pages allocated
doc_trunc	DB 0					; set if the document overflowed the cap
doc_wpage	DB 0					; current write page index
doc_woff	DW 0					; write offset within write page (0..0x4000)
doc_lines	DW 0					; total line count (set by COUNT_LINES)
doc_rpage	DB 0					; read cursor page index
doc_roff	DW 0					; read cursor offset within page

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
	LD		HL, 0
	LD		(doc_woff), HL
	LD		(doc_roff), HL
	LD		(doc_lines), HL
	RET

; ------------------------------------------------------
; MAP_PAGE - map logical page A into WIN3 by writing its cached physical page
; byte to the PAGE3 MMU port (#E2). One OUT, no syscall. Preserves BC, DE, HL.
; Valid only with ISA closed (normal RAM mapping); doc pages and ISA take turns.
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
	JR		NZ, .haspace			; current page has room
.grow
	CALL	.new_page
	JR		C, .dropall
	LD		HL, DOC_PAGE_SIZE
.haspace
	; n = min(space=HL, len=.len)
	LD		BC, (.len)
	PUSH	HL
	OR		A
	SBC		HL, BC					; space - len; CF=1 if space < len
	POP		HL
	JR		NC, .n_is_len			; space >= len -> n = len
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
	PUSH	BC						; save n
	LDIR
	POP		BC						; BC = n
	LD		(.src), HL				; src advanced past copied bytes
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

; allocate one more page; CF=1 (and doc_trunc set) if cap reached / alloc fails.
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
	; resolve the block's physical page list into doc_phys[npages] (#FF-terminated)
	CALL	.phys_addr				; HL = &doc_phys[npages]
	LD		A, D					; A = block handle
	LD		C, BIOS_EMM_FN5
	RST		BIOS
	JR		C, .np_freefail			; cannot resolve -> free and fail
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
; HL = &doc_blocks[doc_npages]
.slot_addr
	LD		HL, doc_blocks
	JR		.idx
; HL = &doc_phys[doc_npages]
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
; Preserves BC, DE, HL (NEXT_LINE keeps its LINE_BUF write pointer in HL across
; this call, so AT_END must NOT clobber HL). Trashes A.
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
; Re-maps the read page into WIN3 every call (cheap OUT), so it stays correct
; even after a DSS/BIOS print clobbered WIN3. Preserves BC, DE, HL.
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
; SEEK_LINE - position the read cursor at the start of line BC (0-based).
; ------------------------------------------------------
SEEK_LINE
	XOR		A
	LD		(doc_rpage), A
	LD		HL, 0
	LD		(doc_roff), HL
.s
	LD		A, B
	OR		C
	RET		Z
	CALL	SKIP_LINE
	DEC		BC
	JR		.s

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
; COUNT_LINES - scan the whole document, set doc_lines (counts a trailing
; partial line with no terminating LF).
; ------------------------------------------------------
COUNT_LINES
	XOR		A
	LD		(doc_rpage), A
	LD		HL, 0
	LD		(doc_roff), HL
	LD		(doc_lines), HL
	LD		C, 0					; C = data-seen-since-last-LF flag
.l
	CALL	AT_END
	JR		C, .tail
	CALL	RD_BYTE					; preserves BC
	CP		10
	JR		Z, .lf
	CP		13
	JR		Z, .l
	LD		C, 1
	JR		.l
.lf
	LD		HL, (doc_lines)
	INC		HL
	LD		(doc_lines), HL
	LD		C, 0
	JR		.l
.tail
	LD		A, C
	OR		A
	RET		Z
	LD		HL, (doc_lines)
	INC		HL
	LD		(doc_lines), HL
	RET

	ENDMODULE
