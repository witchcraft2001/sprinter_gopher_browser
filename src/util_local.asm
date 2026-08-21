; ======================================================
; UTIL - small local utility routines (v0.2.0 UNET migration).
; Replaces the ESP-AT kit's src/lib/util.asm + wcommon.asm INIT_VMODE/EXIT,
; which are no longer statically linked. DELAY/STRLEN/UTOA are ports of Roman
; Boykov's sprinter_wifi/network util.asm (BSD 3-Clause), kept under the same
; MODULE UTIL name so existing main.asm call sites are unchanged.
; ======================================================

	MODULE UTIL

; In: HL = cycles (0 -> 20). Trashes nothing (preserves AF/BC/HL).
DELAY
	PUSH	AF, BC, HL
	LD		A, H
	OR		L
	JR		NZ, .next
	LD		HL, 20
.next
	CALL	.delay_1ms
	DEC		HL
	LD		A, H
	OR		L
	JP		NZ, .next
	POP		HL, BC, AF
	RET
.delay_1ms
	LD		BC, 400
.spin
	DEC		BC
	LD		A, B
	OR		C
	JR		NZ, .spin
	RET

; In: HL = ASCIIZ string. Out: BC = length (excludes the NUL). Preserves HL.
STRLEN
	PUSH	DE, HL
	PUSH	HL
	LD		BC, 0x4000
	XOR		A
	CPIR
	POP		DE
	SBC		HL, DE
	LD		B, H
	LD		C, L
	LD		A, B
	OR		C
	JR		Z, .done
	DEC		BC
.done
	POP		HL, DE
	RET

; In: HL = 16-bit number, DE = dest buffer. Out: DE -> past the written NUL.
UTOA
	PUSH	BC, HL
	XOR		A
	PUSH	AF					; end marker: A=0, ZF=1
.digits
	CALL	.div10
	ADD		A, '0'
	PUSH	AF					; a digit: A>0, ZF=0
	LD		A, H
	OR		L
	JR		NZ, .digits
.emit
	POP		AF
	LD		(DE), A
	INC		DE
	JR		NZ, .emit
	POP		HL, BC
	RET

; In: HL = number. Out: HL = quotient, A = remainder (0..9). Trashes BC.
.div10
	PUSH	BC
	LD		BC, 0x0D0A
	XOR		A
	ADD		HL, HL
	RLA
	ADD		HL, HL
	RLA
	ADD		HL, HL
	RLA
.loop
	ADD		HL, HL
	RLA
	CP		C
	JR		C, .skip
	SUB		C
	INC		L
.skip
	DJNZ	.loop
	POP		BC
	RET

	ENDMODULE

; ------------------------------------------------------
; Video mode save/restore + program exit. Not under MODULE UTIL - main.asm
; calls these unqualified (INIT_VMODE / EXIT), matching the old WCOMMON names.
; ------------------------------------------------------
; CRLF terminator printed by macro.inc's PRINTLN_HL (kept out of macro.inc
; itself - that file is included before the EXE header's ORG, where a DB would
; corrupt the raw output; see the note there).
MACRO_LINE_END	DB 13, 10, 0

save_vmode	DB 0

; Save the current video mode and select 80x32 without clearing the console.
INIT_VMODE
	PUSH	BC
	LD		C, DSS_GETVMOD
	RST		DSS
	LD		(save_vmode), A
	CP		DSS_VMOD_T80
	JR		Z, .already80
	LD		C, DSS_SETVMOD
	LD		A, DSS_VMOD_T80
	RST		DSS
.already80
	POP		BC
	RET

; Restore the saved video mode (best-effort) and exit via DSS. In: B = exit code.
EXIT
	PUSH	BC
	LD		A, (save_vmode)
	CP		DSS_VMOD_T80
	JR		Z, .same
	LD		C, DSS_SETVMOD
	RST		DSS
.same
	POP		BC
	DSS_EXEC DSS_EXIT
