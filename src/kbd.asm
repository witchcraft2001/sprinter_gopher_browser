; ======================================================
; KBD - keyboard input over the DSS API.
; ======================================================

	MODULE KBD

; Non-blocking poll. Out: ZF=1 no key; else A=char code, D=positional code,
; E=ASCII, C=modifier mask. Test A against KEY_ENTER/KEY_ESC and D against
; the KEY_UP/DOWN/LEFT/RIGHT positional codes.
SCAN
	LD		C, DSS_SCANKEY
	RST		DSS
	RET

	ENDMODULE
