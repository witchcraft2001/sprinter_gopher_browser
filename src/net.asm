; ======================================================
; NET - network HAL. Backend selected at build time.
; Phase 2: ESP-AT (Sprinter-WiFi) backend, wrapping the network-kit libs.
; The NE2000/RTL8019A backend (Phase 4) will provide the same NET.* entries.
; ======================================================

	MODULE NET

	IFDEF BACKEND_ESP

TCP_OPEN_RETRY_DELAY	EQU 500			; ms settle before the second TCP.OPEN attempt

; Bring the link up once. Out: CF=0 ok, CF=1 fail (A=ESP result code).
; Mirrors the kit's wget init (NO ISA_RESET - that resets the card and breaks the
; ESP session NETUP set up; it was the main cause of flaky "init failed"). Drains
; stale UART bytes, recovers a flaky first AT, and enables hardware RTS/CTS flow
; control (SETUP_UART_FLOW) so the ESP holds its TX while we do slow work.
INIT
	CALL	WIFI.UART_FIND
	RET		C
	CALL	CHECK_NET_UP				; CF=1 if NETUP not run (no program exit)
	RET		C
	CALL	NETCFG.LOAD
	CALL	NETCFG.APPLY_UART_BAUD
	CALL	WIFI.UART_INIT
	CALL	WIFI.UART_EMPTY_RS			; drop stale boot / +IPD bytes before talking
	LD		HL, CMD_AT
	CALL	AT_RECOVER					; AT, with one ESP-reset retry if it stalls
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

; Send AT command HL; on failure reset the ESP + re-init the UART and retry once.
AT_RECOVER
	PUSH	HL
	CALL	TX_CMD
	POP		HL
	RET		NC
	CALL	WIFI.ESP_RESET
	CALL	WIFI.UART_SET_DEFAULT_DIVISOR
	CALL	WIFI.UART_INIT
	CALL	WIFI.UART_EMPTY_RS
	JP		TX_CMD

; In: HL=host ASCIIZ, DE=port ASCIIZ. CF=0 connected. Prepares the socket (drops
; any stale connection, drains RX) and retries the open once - the first open
; after an idle/closed socket often needs a settle, which is the "Send failed" /
; connect flakiness.
CONNECT
	LD		(c_host), HL
	LD		(c_port), DE
	CALL	.prep
	LD		HL, (c_host)
	LD		DE, (c_port)
	CALL	TCP.OPEN
	RET		NC
	CALL	.prep
	LD		HL, TCP_OPEN_RETRY_DELAY
	CALL	UTIL.DELAY
	LD		HL, CMD_AT
	CALL	TX_CMD
	LD		HL, CMD_CIPMUX_0
	CALL	TX_CMD
	LD		HL, (c_host)
	LD		DE, (c_port)
	JP		TCP.OPEN
.prep
	CALL	WIFI.UART_RX_RESUME
	CALL	TCP.CLOSE					; drop any stale single-connection socket
	CALL	WIFI.UART_EMPTY_RS
	RET
c_host	DW 0
c_port	DW 0

; In: HL=buffer, BC=length. Send without waiting for "SEND OK" (a fast server can
; start replying before it; RECEIVE scans past the prompt/SEND OK itself).
SEND
	JP		TCP.SEND_BUFFER_NO_WAIT

; In: HL=dest, BC=max, DE=timeout(ms). Out: BC=stored bytes, CF=1 on end/error.
RECV
	JP		TCP.RECEIVE

CLOSE
	JP		TCP.CLOSE

; Hardware RX flow control (RTS via the TL16C550 AFE). Drop RTS around slow work
; so the ESP holds its TX (no UART FIFO overrun); raise it before receiving.
RX_PAUSE
	JP		WIFI.UART_RX_PAUSE
RX_RESUME
	JP		WIFI.UART_RX_RESUME

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
