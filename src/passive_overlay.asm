; ESP-AT 2.2.2 passive single-connection receive overlay.
; Assembled to LINE_BUF and loaded from the non-loader tail of GOPHER.EXE only
; while a 2.2.2 binary download is active. LINE_BUF is not used during download.
;
; PROBE-DRIVEN POLLING: AT+CIPRECVDATA is issued directly for whatever the
; caller can store; +IPD values are never parsed. Control waits run on a short
; PASSIVE_POLL_MS tick with a PASSIVE_POLL_TRIES budget per RECV call: a wake
; (+IPD/CLOSED line) probes immediately, and a QUIET tick probes anyway.
; CIPRECVDATA works regardless of the firmware's +IPD "reported" flag, so a
; missing/suppressed notification (the flag survives NO DATA replies and gates
; the link OUT of the firmware's select() set - disassembly-verified) can stall
; this design for at most one tick, never kill the transfer. The first receive
; after the request never probes: SEND_BUFFER_NO_WAIT returns while the ESP is
; still inside AT+CIPSEND, and a command in that busy window is DISCARDED
; ("busy p..."); the first wait absorbs the send chatter. CLOSED only sets a
; flag: buffered data survives the peer FIN in passive mode, so EOF is reported
; strictly as closed AND probe-confirmed-drained. That is what makes a passive
; download tail-exact.
;
; NEVER ABANDON A DATA BLOCK (v0.1.19). The control tick paces PROBES, not
; payload: once "+CIPRECVDATA:<len>," is seen, the length digits and all <len>
; bytes are read on the long PASSIVE_DATA_MS timeout, and a block that does not
; fit the caller's buffer is RESUMED by the next call (TCP.PAYLOAD_LEFT
; persists, exactly as the kit's active reader does). A probe is re-sent only
; while none is outstanding, or after its tick expired with nothing stored -
; and pv_live makes the next call continue the outstanding one instead of
; starting a new scan. Earlier builds could consume a header inside an idle
; wait and then re-probe, which silently dropped the whole block behind it and
; resynchronised on the next OK: a >1.5 s ESP hiccup mid-response (Wi-Fi
; retransmits) was enough, so the odds grew with transfer length - files past
; ~0.5 MB came out complete-looking but with holes.

	MODULE NET

PASSIVE_POLL_MS		EQU 1500		; control tick: paces probes only
PASSIVE_DATA_MS		EQU 10000		; length + payload bytes of a live block
; Quiet ticks tolerated per RECV call (~60 s). A gateway that buffers the whole
; upstream file before answering (gopher-gate does) can leave the socket silent
; for tens of seconds on a big item; Esc still cancels at any point.
PASSIVE_POLL_TRIES	EQU 40

; ACTIVE_PREP reaches these entries only after this overlay has been loaded.
PASSIVE_SETUP_222
	XOR		A
	LD		(pv_closed), A
	LD		(pv_live), A
	LD		(pv_llen), A			; the line scanner starts at a line boundary
	LD		HL, 0
	LD		(TCP.PAYLOAD_LEFT), HL	; no block is in flight on a fresh socket
	LD		A, 1
	LD		(pv_first), A			; first RECV must wait out the send window
	LD		HL, CMD_CIPRECVMODE_1
	CALL	TX_CMD
	RET		C
	LD		HL, CMD_CIPDINFO_0		; fixed +CIPRECVDATA:<len>,<data> response
	JP		TX_CMD

RECV_PASSIVE_222
	LD		(TCP.RECV_PTR), HL
	LD		(TCP.RECV_REMAIN), BC
	LD		HL, 0
	LD		(TCP.RECV_STORED), HL
	LD		A, PASSIVE_POLL_TRIES
	LD		(pv_poll), A

	CALL	ISA.ISA_OPEN			; every resume path starts by reading the UART
	LD		HL, (TCP.PAYLOAD_LEFT)
	LD		A, H
	OR		L
	JP		NZ, .payload			; finish the block split by the last call
	LD		A, (pv_live)
	OR		A
	JP		NZ, .resp				; a probe is outstanding: keep reading its reply
	LD		A, (pv_first)
	OR		A
	JR		Z, .rearm				; no probe out: close the window and send one
	XOR		A
	LD		(pv_first), A
	LD		HL, PASSIVE_POLL_MS
	LD		(TCP.RECV_TIMEOUT), HL
	JP		.empty_eval				; wait first: the CIPSEND busy window is live

.probe
	LD		HL, (TCP.RECV_REMAIN)
	LD		DE, TCP.NUM_BUFFER
	CALL	UTIL.UTOA
	LD		HL, TCP.CMD_BUFFER
	LD		DE, CMD_CIPRECVDATA_PREFIX
	CALL	TCP.APPEND_STR
	LD		DE, TCP.NUM_BUFFER
	CALL	TCP.APPEND_STR
	LD		DE, STR_CRLF
	CALL	TCP.APPEND_STR
	LD		HL, TCP.CMD_BUFFER
	CALL	WIFI.UART_TX_STRING
	JP		C, .tx_fail
	LD		A, 1
	LD		(pv_live), A
	CALL	ISA.ISA_OPEN
.resp
	; Read the outstanding probe's reply: a data header, or its OK/ERROR end.
	LD		HL, PASSIVE_POLL_MS
	LD		(TCP.RECV_TIMEOUT), HL
	XOR		A
	CALL	PASSIVE_RESPONSE
	JR		C, .resp_quiet
	OR		A
	JR		Z, .data
	XOR		A
	LD		(pv_live), A			; OK/ERROR terminates the probe
	LD		HL, (TCP.RECV_STORED)
	LD		A, H
	OR		L
	JP		NZ, .stored_ok
.empty_eval
	; Nothing buffered for us (empty probe, or the first-call send window).
	LD		A, (pv_closed)
	OR		A
	JR		NZ, .eof_open			; closed + drained = byte-exact EOF
	LD		A, 1
	CALL	PASSIVE_RESPONSE		; tick: wake on +IPD/CLOSED or time out
	JR		C, .tick				; quiet -> spend a tick and probe again
	OR		A
	JR		Z, .data				; a late reply arrived: take its block
	JR		.rearm					; woken: probe now, no tick spent
.resp_quiet
	; The outstanding probe stayed silent for a tick. Bytes already stored are
	; returned as they are; pv_live keeps the next call reading the same reply.
	LD		HL, (TCP.RECV_STORED)
	LD		A, H
	OR		L
	JR		NZ, .stored_ok
.tick
	LD		A, (WCOMMON.CANCELLED)
	OR		A
	JR		NZ, .quiet_fail			; cancel must not turn into another probe
	LD		HL, pv_poll
	DEC		(HL)
	JR		Z, .quiet_fail			; budget exhausted with no data at all
.rearm
	CALL	ISA.ISA_CLOSE
	JP		.probe					; probe regardless: data may sit unannounced
.quiet_fail
	LD		A, RES_RS_TIMEOUT
	JR		.fail_open

.data
	LD		HL, PASSIVE_DATA_MS		; a live block is never abandoned mid-way
	LD		(TCP.RECV_TIMEOUT), HL
	CALL	PASSIVE_READ_DEC		; digits up to the ',' (anything else = error)
	JR		C, .fail_open
	LD		A, H
	OR		L
	JP		Z, .resp				; empty block: just wait for its terminal
	LD		(TCP.PAYLOAD_LEFT), HL
.payload
	LD		HL, PASSIVE_DATA_MS
	LD		(TCP.RECV_TIMEOUT), HL
	CALL	TCP.READ_PAYLOAD		; stores at most RECV_REMAIN: no overrun
	JR		C, .quiet_fail			; CF only when nothing at all was stored
	LD		HL, (TCP.PAYLOAD_LEFT)
	LD		A, H
	OR		L
	JR		NZ, .stored_ok			; buffer full: the next call resumes the block
	JP		.resp					; block complete -> read its trailing OK
.stored_ok
	CALL	ISA.ISA_CLOSE
	LD		BC, (TCP.RECV_STORED)
	XOR		A
	RET

.eof_open
	LD		A, RES_NOT_CONN
.fail_open
	PUSH	AF
	CALL	ISA.ISA_CLOSE
	POP		AF
	SCF
	RET
.tx_fail
	LD		A, RES_TX_TIMEOUT
	SCF
	RET

; Scan the AT control stream after (or between) CIPRECVDATA probes.
; In: A = 0 normal (finish on OK/ERROR or a data header), 1 = idle-wait (also
; return on a completed "+..." line - i.e. +IPD - or on CLOSED, so the prober
; re-probes exactly when data may be available; noise lines such as "Recv N
; bytes"/"SEND OK"/"busy p..." never wake it).
; Out: CF=1 timeout/cancel (A=RES_RS_TIMEOUT); CF=0 with A: 0 = "+CIPRECVDATA:"
; header consumed (length follows), 1 = OK/ERROR line (no data), 2 = woken
; (idle-wait only). A CLOSED line anywhere sets pv_closed; +IPD payload
; lengths are never parsed (the probe asks the ESP directly).
;
; The scan state (pv_lch/pv_llen) is the position inside the CURRENT line and
; deliberately SURVIVES a timeout return: the AT stream is continuous, so a
; control tick that expires halfway through a line must resume where it stopped.
; Resetting it per call used to drop the "+CIPRECVDATA:" header when an ESP
; stall split it, and the whole data block behind it went to the line scanner.
; The header is recognised from that same state - a ':' closing a 12-char line
; that began with '+' - so no separate prefix matcher (or its string) is needed;
; no other '+' line can appear on this connection.
PASSIVE_RESPONSE
	LD		(pv_wake), A
.next
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	LD		E, A
	CP		':'
	JR		NZ, .classify
	LD		A, (pv_lch)
	CP		'+'
	JR		NZ, .classify
	LD		A, (pv_llen)
	CP		12						; "+CIPRECVDATA" -> the length follows
	JR		NZ, .classify
	XOR		A
	LD		(pv_llen), A
	RET								; A=0, CF=0
.classify
	LD		A, E
	CP		13
	JR		Z, .next				; CR ignored; LF terminates a line
	CP		10
	JR		Z, .eol
	LD		A, (pv_llen)
	OR		A
	JR		NZ, .not_first
	LD		A, E
	LD		(pv_lch), A
.not_first
	LD		HL, pv_llen
	INC		(HL)
	JR		.next
.eol
	LD		A, (pv_llen)
	OR		A
	JR		Z, .next				; blank line
	LD		D, A
	XOR		A
	LD		(pv_llen), A			; the line ends here whatever it turns out to be
	LD		A, (pv_lch)
	CP		'O'						; "OK"
	JR		NZ, .not_ok
	LD		A, D
	CP		2
	JR		NZ, .next
.done_line
	LD		A, 1
	RET
.not_ok
	CP		'E'						; "ERROR" (empty buffer probes may answer this)
	JR		NZ, .not_err
	LD		A, D
	CP		5
	JR		Z, .done_line
	JR		.next
.not_err
	CP		'C'						; "CLOSED"
	JR		NZ, .async
	LD		A, D
	CP		6
	JR		NZ, .async
	LD		A, 1
	LD		(pv_closed), A
	JR		.wake_chk				; CLOSED wakes the idle-wait (drain follows)
.async
	LD		A, (pv_lch)
	CP		'+'						; only +IPD-style lines signal buffered data
	JR		NZ, .next
.wake_chk
	LD		A, (pv_wake)
	OR		A
	JR		Z, .next
	LD		A, 2					; idle-wait: wake the prober
	RET
.timeout
	LD		A, RES_RS_TIMEOUT		; mid-line state is kept for the next call
	SCF
	RET

PASSIVE_READ_DEC
	LD		HL, 0
.next
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	CP		','						; the header's ':' was eaten by the matcher
	JR		Z, .delim
	CP		'0'
	JR		C, .error
	CP		'9' + 1
	JR		NC, .error
	SUB		'0'
	LD		E, A
	LD		D, 0
	LD		B, H
	LD		C, L
	ADD		HL, HL
	ADD		HL, HL
	ADD		HL, BC
	ADD		HL, HL
	ADD		HL, DE
	JR		.next
.delim
	XOR		A
	RET
.timeout
	LD		A, RES_RS_TIMEOUT
	SCF
	RET
.error
	LD		A, RES_ERROR
	SCF
	RET

	ENDMODULE

	MODULE MAIN

; 2.2.2 passive pull -> immediate 4 KB FAT writes. No DOC banks are allocated.
DL_RECV_FILE_222
	XOR		A
	LD		(TCP.LSR_ACCUM), A
	LD		HL, (WCOMMON.IDLE_CB)
	LD		(recv_idle_cb), HL
	LD		HL, 0
	LD		(WCOMMON.IDLE_CB), HL
	LD		(dl_comb), HL
.loop
	CALL	NET.RX_RESUME
	LD		DE, (dl_comb)
	LD		HL, DL_BUF
	ADD		HL, DE
	PUSH	HL
	LD		HL, DL_BUF_SIZE
	OR		A
	SBC		HL, DE
	LD		B, H
	LD		C, L
	POP		HL
	LD		DE, RECV_TIMEOUT
	CALL	NET.RECV
	PUSH	AF
	CALL	NET.RX_PAUSE
	POP		AF
	JR		C, .end
	LD		HL, (dl_comb)
	ADD		HL, BC
	LD		(dl_comb), HL
	CALL	DL_PROGRESS_ACC
	LD		HL, (dl_comb)
	LD		DE, DL_BUF_SIZE
	OR		A
	SBC		HL, DE
	JR		NZ, .loop
	CALL	.flush
	JR		C, .disk
	JR		.loop
.end
	CP		RES_NOT_CONN
	JR		NZ, .fail
	LD		A, (TCP.LSR_ACCUM)
	AND		LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
	JR		NZ, .uart
	CALL	.flush
	JR		C, .disk
	CALL	NET.RX_RESUME
	LD		HL, (recv_idle_cb)
	LD		(WCOMMON.IDLE_CB), HL
	OR		A
	RET
.flush
	LD		BC, (dl_comb)
	LD		A, B
	OR		C
	RET		Z
	PUSH	BC
	LD		HL, DL_BUF
	CALL	FILE.WRITE
	POP		BC
	RET		C
	CALL	DL_ADD
	LD		HL, 0
	LD		(dl_comb), HL
	LD		(dl_pending), HL
	OR		A
	RET
.disk
	LD		A, 1
	LD		(dl_disk_err), A
	JR		.fail
.uart
	LD		A, 2
	LD		(dl_disk_err), A
.fail
	CALL	NET.RX_RESUME
	LD		HL, (recv_idle_cb)
	LD		(WCOMMON.IDLE_CB), HL
	SCF
	RET

	ENDMODULE
