; ======================================================
; NET - network HAL. Backend selected at build time.
; Phase 2: ESP-AT (Sprinter-WiFi) backend, wrapping the network-kit libs.
; The NE2000/RTL8019A backend (Phase 4) will provide the same NET.* entries.
; ======================================================

	MODULE NET

	IFDEF BACKEND_ESP

; Bring the link up. Out: CF=0 ok, CF=1 fail (A=ESP result code).
; Missing card or "NETUP not run" are reported and the program exits via the
; kit's own handlers (WIFI.UART_FIND CF / WCOMMON.REQUIRE_NET_UP).
INIT
	CALL	ISA.ISA_RESET
	CALL	WIFI.UART_FIND
	RET		C
	CALL	CHECK_NET_UP				; CF=1 if NETUP not run (no program exit)
	RET		C
	CALL	NETCFG.LOAD
	CALL	NETCFG.APPLY_UART_BAUD
	CALL	WIFI.UART_INIT
	LD		HL, CMD_AT
	CALL	TX_CMD
	RET		C
	LD		HL, CMD_ECHO_OFF
	CALL	TX_CMD
	RET		C
	CALL	WCOMMON.SETUP_UART_FLOW
	AND		A
	JR		Z, .flow_ok
	SCF
	RET
.flow_ok
	LD		HL, CMD_CIPMUX_0
	CALL	TX_CMD
	RET		C
	XOR		A
	RET

; Send AT command at HL (ASCIIZ). Out: CF=0 ok, CF=1 on UART error.
TX_CMD
	LD		DE, WIFI.RS_BUFF
	LD		BC, DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND		A
	RET		Z
	SCF
	RET

; In: HL=host ASCIIZ, DE=port ASCIIZ. CF=0 connected.
CONNECT
	JP		TCP.OPEN

; In: HL=buffer, BC=length.
SEND
	JP		TCP.SEND_BUFFER

; In: HL=dest, BC=max, DE=timeout(ms). Out: BC=stored bytes, CF=1 on end/error.
RECV
	JP		TCP.RECEIVE

CLOSE
	JP		TCP.CLOSE

; Hand the ESP back in AT command mode for the next program: close any lingering
; socket (AT+CIPCLOSE) and re-assert echo-off. Best-effort; ignores errors. Call
; on program exit if the UART was ever initialised. (We use CIPMODE=0 throughout,
; so no transparent-mode "+++" escape is needed, unlike SpecTalkZX.)
SHUTDOWN
	CALL	TCP.CLOSE
	LD		HL, CMD_ECHO_OFF
	CALL	TX_CMD
	RET

CMD_AT			DB "AT", 13, 10, 0
CMD_ECHO_OFF	DB "ATE0", 13, 10, 0
CMD_CIPMUX_0	DB "AT+CIPMUX=0", 13, 10, 0

; Verify NETUP joined Wi-Fi (env NET=WIFI and NET_ESP_HW set). Returns CF=1 on
; failure instead of exiting the program (unlike WCOMMON.REQUIRE_NET_UP), so the
; browser can report the error and stay running. Reuses the kit's env strings.
CHECK_NET_UP
	LD		HL, WCOMMON.N_NET_KEY
	LD		DE, WCOMMON.ENV_VAL_BUF
	LD		B, ENV_GET
	LD		C, DSS_ENVIRON
	RST		DSS
	OR		A
	JR		Z, .fail					; NET not set
	LD		HL, WCOMMON.ENV_VAL_BUF
	LD		DE, WCOMMON.V_WIFI
	CALL	.strmatch
	JR		NZ, .fail					; NET != WIFI
	LD		HL, WCOMMON.N_ESP_HW_KEY
	LD		DE, WCOMMON.ENV_VAL_BUF
	LD		B, ENV_GET
	LD		C, DSS_ENVIRON
	RST		DSS
	OR		A
	JR		Z, .fail					; NET_ESP_HW not set
	LD		A, (WCOMMON.ENV_VAL_BUF)
	OR		A
	JR		Z, .fail					; NET_ESP_HW empty
	OR		A							; CF=0 ok
	RET
.fail
	SCF
	RET
; Compare ASCIIZ at HL and DE. Out: ZF=1 if equal. Trashes A, C, HL, DE.
.strmatch
	LD		A, (DE)
	LD		C, A
	LD		A, (HL)
	CP		C
	RET		NZ
	OR		A
	RET		Z
	INC		HL
	INC		DE
	JR		.strmatch

	ENDIF

	ENDMODULE
