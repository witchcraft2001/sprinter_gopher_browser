; ======================================================
; KBD - keyboard input over the DSS API.
; ======================================================

	MODULE KBD

; Non-blocking poll. Out: ZF=1 no key; else A=char code, D=positional code,
; E=ASCII, B=shift-state mask (KB_CTRL/KB_*SHIFT...), C=keyboard layout mode.
; Test A against KEY_ENTER/KEY_ESC and D against the KEY_UP/DOWN/LEFT/RIGHT
; positional codes; AND B with KB_CTRL|KB_L_CTRL|KB_R_CTRL for Ctrl combos.
SCAN
	LD		C, DSS_SCANKEY
	RST		DSS
	RET

	ENDMODULE
