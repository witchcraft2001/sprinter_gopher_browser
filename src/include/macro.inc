; ======================================================
; Local macro shims (v0.2.2 UNETLD migration). Replaces the ESP-AT kit's
; macro.inc now that the kit is no longer statically linked; keeps only what
; main.asm actually uses (PRINTLN, DSS_EXEC).
; ======================================================

	IFNDEF	_MOONRABBIT_MACRO_INC
	DEFINE	_MOONRABBIT_MACRO_INC

	MACRO	PRINT_HL
	LD		C, DSS_PCHARS
	RST		DSS
	ENDM

	MACRO	PRINTLN_HL
	PRINT_HL
	LD		HL, MACRO_LINE_END
	PRINT_HL
	ENDM

	MACRO	PRINTLN	data
	LD		HL, data
	PRINTLN_HL
	ENDM

	; Execute specified DSS function
	MACRO	DSS_EXEC	func
		IF func>255
			LD		BC, func
		ELSE
			LD		C, func
		ENDIF
		RST		DSS
	ENDM

; NOTE: MACRO_LINE_END (the CRLF,0 string PRINTLN_HL prints) is deliberately
; NOT emitted here: this file is included before the EXE header's ORG, and any
; bytes emitted there land at the very start of the --raw output, shifting the
; whole EXE image. The label lives in util_local.asm, inside the loaded image.

	ENDIF
