; ======================================================
; NET - network HAL. Backend selected at build time.
; Phase 2: ESP-AT (Sprinter-WiFi) backend, wrapping the network-kit libs.
; The NE2000/RTL8019A backend (Phase 4) will provide the same NET.* entries.
; ======================================================

	MODULE NET

	IFDEF BACKEND_ESP

TCP_OPEN_RETRY_DELAY	EQU 500			; ms settle before the second TCP.OPEN attempt
RAW_RX_SPIN_BUDGET	EQU 200			; bridge gaps between raw UART FIFO bursts

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
; A user cancel (Esc/Ctrl+Z, kit sets WCOMMON.CANCELLED) aborts instead of retrying.
AT_RECOVER
	PUSH	HL
	CALL	TX_CMD
	POP		HL
	RET		NC
	LD		A, (WCOMMON.CANCELLED)
	OR		A
	SCF
	RET		NZ						; cancelled -> abort
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
	LD		A, (WCOMMON.CANCELLED)
	OR		A
	SCF
	RET		NZ						; cancelled during open -> abort, no retry
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

; Active ESP-AT transport. Binary downloads deliberately use CIPMODE=0: every
; +IPD frame carries an explicit payload length and TCP.RECEIVE consumes exactly
; that many bytes. This avoids transparent mode's silent FIN-tail loss.
SEND
	JP		TCP.SEND_BUFFER_NO_WAIT

RECV
	JP		TCP.RECEIVE

CLOSE
	JP		TCP.CLOSE

; Prepare diagnostics/parser state immediately before a new active-mode request.
; Finish with RTS asserted because START_SEND_BUFFER must receive the '>' prompt.
ACTIVE_PREP
	CALL	WIFI.UART_RX_PAUSE
	XOR		A
	LD		(TCP.LSR_ACCUM), A
	LD		(TCP.LAST_LSR), A
	LD		(TCP.IPD_BAD_CHAR), A
	LD		HL, 0
	LD		(TCP.PAYLOAD_LEFT), HL
	JP		WIFI.UART_RX_RESUME

; ------------------------------------------------------
; Transparent/raw TCP transport for gopher page fetches only.
;
; jesperl's active +IPD mode can discard a repeatable ~2 KB tail when the peer
; closes (clean CLOSED, no UART error). CIPMODE=1 bypasses that queue: after
; AT+CIPSEND the TCP stream is a raw UART pipe, as proven by the kit's telnet.
; ------------------------------------------------------

; HL=host, DE=port. Enter transparent mode and the raw pipe. CF=1 on failure;
; failure cleanup restores CIPMODE=0 so the next request/program is safe.
RAW_CONNECT
	LD		(raw_host), HL
	LD		(raw_port), DE
	LD		HL, CMD_CIPMODE_1
	CALL	TX_CMD
	JR		C, .fail_mode
	LD		HL, (raw_host)
	LD		DE, (raw_port)
	; Normal raw fetches finish on the peer's CLOSED and therefore have no stale
	; socket. Open directly: CONNECT's unconditional pre-CIPCLOSE costs the full
	; 5 s timeout when the socket is already gone. Only fall back to that slower
	; stale-link recovery path after a real OPEN failure.
	CALL	TCP.OPEN
	JR		NC, .enter
	LD		A, (WCOMMON.CANCELLED)
	OR		A
	JR		NZ, .fail
	LD		HL, (raw_host)
	LD		DE, (raw_port)
	CALL	CONNECT
	JR		C, .fail
.enter
	CALL	RAW_ENTER
	RET		NC
.fail
	LD		(raw_err), A
	CALL	TCP.CLOSE
	LD		HL, CMD_CIPMODE_0
	CALL	TX_CMD
	LD		A, (raw_err)
	SCF
	RET
.fail_mode
	SCF
	RET

; AT+CIPSEND -> wait for the '>' prompt. The first server byte remains queued
; for RAW_RECV because we stop exactly at the prompt.
RAW_ENTER
	CALL	WIFI.UART_RX_RESUME
	CALL	WIFI.UART_EMPTY_RS
	LD		HL, CMD_CIPSEND_RAW
	CALL	WIFI.UART_TX_STRING
	RET		C
.wp
	LD		BC, 3000
	CALL	WIFI.UART_WAIT_RS
	JR		C, .timeout
	LD		HL, REG_RBR
	CALL	WIFI.UART_READ
	CP		'>'
	JR		NZ, .wp
	OR		A
	RET
.timeout
	LD		A, RES_RS_TIMEOUT
	SCF
	RET

; Send selector+CRLF directly into the transparent TCP pipe.
RAW_SEND
	JP		WIFI.UART_TX_BUFFER

; Blocking wait for at least one raw byte, then drain the current burst into
; HL (max BC). DE=wait ms. Out: BC=count/CF=0; CF=1/A=RES_RS_TIMEOUT on silence.
RAW_RECV
	PUSH	HL
	PUSH	BC
	LD		B, D
	LD		C, E
	CALL	ISA.ISA_OPEN
	CALL	WIFI.UART_WAIT_RS_INT	; polls Esc/Ctrl+Z through CHECK_CANCEL_IN_ISA
	PUSH	AF
	CALL	ISA.ISA_CLOSE
	POP		AF
	POP		BC
	POP		HL
	JR		C, .timeout
	JP		RAW_DRAIN
.timeout
	LD		A, RES_RS_TIMEOUT
	SCF
	RET

; Non-blocking raw UART burst drain. In HL=buffer, BC=max; out BC=count, CF=0.
RAW_DRAIN
	PUSH	BC
	CALL	ISA.ISA_OPEN
	POP		BC
	LD		DE, 0					; count
.l
	LD		A, D
	CP		B
	JR		C, .room
	JR		NZ, .done
	LD		A, E
	CP		C
	JR		NC, .done
.room
	LD		A, RAW_RX_SPIN_BUDGET
	LD		(raw_spin), A
.spin
	LD		A, (REG_LSR)
	LD		(raw_last_lsr), A
	AND	LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
	JR		Z, .lsr_ok
	LD		(raw_lsr_err), A		; any hardware RX error invalidates binary data
.lsr_ok
	LD		A, (raw_last_lsr)
	AND	LSR_DR
	JR		NZ, .got
	LD		A, (raw_spin)
	DEC		A
	LD		(raw_spin), A
	JR		NZ, .spin
	JR		.done
.got
	LD		A, (REG_RBR)
	LD		(HL), A
	INC		HL
	INC		DE
	JR		.l
.done
	CALL	ISA.ISA_CLOSE
	LD		B, D
	LD		C, E
	XOR		A
	RET

; Receive setup for opaque binary data. Keep the normal TR8 trigger: lowering
; the trigger to TR4 makes RTS fall earlier and lengthens the ESP back-pressure
; window. On peer FIN that can make ESP-AT discard a clean (but still queued)
; tail even though the UART reports no OE/PE/FE error. We still clear and latch
; LSR diagnostics so genuine UART corruption is rejected.
RAW_SAFE_RX
	CALL	WIFI.UART_RX_PAUSE
	LD		E, FCR_FIFO | FCR_TR8
	LD		HL, REG_FCR
	CALL	WIFI.UART_WRITE
	XOR		A
	LD		(raw_lsr_err), A
	LD		(raw_last_lsr), A
	RET

RAW_NORMAL_RX
	LD		E, FCR_FIFO | FCR_TR8
	LD		HL, REG_FCR
	JP		WIFI.UART_WRITE

; Out: ZF=1 if no UART receive error was observed, ZF=0/A=LSR error bits.
RAW_ERRORS
	LD		A, (raw_lsr_err)
	OR		A
	RET

; Leave transparent mode. A=1 means CLOSED was received (or page terminator plus
; quiet grace): probe AT mode first. A=3 means a binary stream already observed
; two seconds of post-data silence, satisfying the pre-+++ guard; start at +++.
; A=0 uses the complete guarded escape.
; Best effort; always returns CF=0 with CIPMODE=0 requested.
RAW_FINISH
	CP		3
	JR		Z, .escape_prequiet
	OR		A
	JR		NZ, .probe_cmd
.escape
	CALL	WIFI.UART_RX_RESUME
	CALL	RAW_QUIET_GUARD
.escape_prequiet
	LD		HL, STR_PLUS3
	CALL	WIFI.UART_TX_STRING
	CALL	RAW_QUIET_GUARD
	LD		HL, STR_CRLF
	CALL	WIFI.UART_TX_STRING
	LD		HL, CMD_ECHO_OFF
	CALL	TX_CMD
	CALL	TCP.CLOSE
	JR		.mode0
.probe_cmd
	LD		HL, CMD_AT
	CALL	TX_CMD					; immediate OK if CLOSED already restored AT mode
	JR		C, .escape				; still transparent -> use the guarded escape
	; CLOSED already destroyed the socket. Do not issue CIPCLOSE: some firmware
	; waits out its full timeout for an already-gone socket.
	LD		HL, CMD_ECHO_OFF
	CALL	TX_CMD
.mode0
	LD		HL, CMD_CIPMODE_0
	CALL	TX_CMD
	CALL	RAW_NORMAL_RX
	OR		A
	RET

; Guard time for the transparent-mode +++ escape. ESP requires >=1 s of TX
; silence; use 1.2 s on each side and discard any remaining raw RX meanwhile.
RAW_QUIET_GUARD
	LD		B, 12
.l
	PUSH	BC
	LD		HL, WIFI.RS_BUFF
	LD		BC, RS_BUFF_SIZE
	CALL	RAW_DRAIN
	LD		HL, 100
	CALL	UTIL.DELAY
	POP		BC
	DJNZ	.l
	RET

; Hardware RX flow control (RTS via the TL16C550 AFE). Drop RTS around slow work
; so the ESP holds its TX (no UART FIFO overrun); raise it before receiving.
RX_PAUSE
	JP		WIFI.UART_RX_PAUSE
RX_RESUME
	JP		WIFI.UART_RX_RESUME

; Hand the ESP back in AT command mode for the next program: close any lingering
; socket (AT+CIPCLOSE) and re-assert echo-off. Best-effort; ignores errors. Call
; on program exit if the UART was ever initialised. Page fetch cleanup restores
; CIPMODE=0 before returning, so shutdown itself stays in AT command mode.
SHUTDOWN
	CALL	TCP.CLOSE
	LD		HL, CMD_ECHO_OFF
	CALL	TX_CMD
	RET

CMD_AT			DB "AT", 13, 10, 0
CMD_ECHO_OFF	DB "ATE0", 13, 10, 0
CMD_CIPMUX_0	DB "AT+CIPMUX=0", 13, 10, 0
CMD_CIPMODE_1	DB "AT+CIPMODE=1", 13, 10, 0
CMD_CIPMODE_0	DB "AT+CIPMODE=0", 13, 10, 0
CMD_CIPSEND_RAW DB "AT+CIPSEND", 13, 10, 0
STR_PLUS3		DB "+++", 0
STR_CRLF		DB 13, 10, 0
raw_host		DW 0
raw_port		DW 0
raw_err			DB 0
raw_spin		DB 0
raw_last_lsr	DB 0
raw_lsr_err		DB 0

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
