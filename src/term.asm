; ======================================================
; TERM - 80x32 text console HAL over the DSS API.
; Thin wrappers; each trashes registers as the underlying DSS call does.
; ======================================================

	MODULE TERM

; Clear the whole screen to ATTR_NORM spaces.
CLS
	LD		D, 0
	LD		E, 0
	LD		H, SCR_H
	LD		L, SCR_W
	LD		B, ATTR_NORM
	LD		A, ' '
	; fall through

; Fill a rectangle and set the colour used by subsequent PUTS/PUTC.
; In: D=row E=col H=height L=width A=fill-char B=attr.
FILL
	LD		C, DSS_CLEAR
	RST		DSS
	RET

; Move the text cursor. In: D=row E=col (0-based).
LOCATE
	LD		C, DSS_LOCATE
	RST		DSS
	RET

; Print ASCIIZ at the cursor. In: HL=string. Uses the current colour.
PUTS
	LD		C, DSS_PCHARS
	RST		DSS
	RET

; Print one character at the cursor. In: A=char.
PUTC
	LD		C, DSS_PUTCHAR
	RST		DSS
	RET

	ENDMODULE
