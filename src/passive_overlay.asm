; ESP-AT 2.2.2 passive single-connection receive overlay.
; Assembled to LINE_BUF and loaded from the non-loader tail of GOPHER.EXE only
; while a 2.2.2 binary download is active. LINE_BUF is not used during download.

	MODULE NET

; ACTIVE_PREP reaches these entries only after this overlay has been loaded.
; HL is still zero from clearing TCP.PAYLOAD_LEFT.
PASSIVE_SETUP_222
	LD		(passive_pending), HL
	LD		HL, CMD_CIPRECVMODE_1
	CALL	TX_CMD
	RET		C
	LD		HL, CMD_CIPDINFO_0		; fixed +CIPRECVDATA:<len>,<data> response
	JP		TX_CMD

RECV_PASSIVE_222
	LD		(TCP.RECV_PTR), HL
	LD		(TCP.RECV_REMAIN), BC
	LD		(TCP.RECV_TIMEOUT), DE
	LD		HL, 0
	LD		(TCP.RECV_STORED), HL

	LD		HL, (passive_pending)
	LD		A, H
	OR		L
	JR		NZ, .choose_len

	CALL	ISA.ISA_OPEN
	CALL	PASSIVE_WAIT_IPD_OR_CLOSE
	JP		C, .fail_open
	CALL	PASSIVE_READ_DEC
	JP		C, .fail_open
	LD		A, (passive_delim)
	CP		13
	JP		NZ, .protocol_open
	LD		A, H
	OR		L
	JP		Z, .protocol_open
	LD		(passive_pending), HL
	CALL	ISA.ISA_CLOSE

.choose_len
	LD		HL, (passive_pending)
	LD		DE, (TCP.RECV_REMAIN)
	OR		A
	SBC		HL, DE
	JR		C, .pending_smaller
	LD		H, D
	LD		L, E
	JR		.have_len
.pending_smaller
	ADD		HL, DE
.have_len
	LD		A, H
	OR		L
	JP		Z, .protocol
	LD		(TCP.IPD_REMOTE_LEN), HL

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
	JR		C, .tx_fail

	CALL	ISA.ISA_OPEN
	CALL	PASSIVE_WAIT_DATA_PREFIX
	JR		C, .fail_open
	CALL	PASSIVE_READ_DEC
	JR		C, .fail_open
	LD		A, (passive_delim)
	CP		','
	JR		NZ, .protocol_open
	LD		(TCP.LAST_IPD_LEN), HL
	LD		DE, (TCP.IPD_REMOTE_LEN)
	OR		A
	SBC		HL, DE
	JR		C, .actual_ok
	LD		A, H
	OR		L
	JR		NZ, .protocol_open
.actual_ok
	LD		HL, (TCP.LAST_IPD_LEN)
	LD		A, H
	OR		L
	JR		Z, .protocol_open
	LD		(TCP.PAYLOAD_LEFT), HL
	CALL	TCP.READ_PAYLOAD
	JR		C, .fail_open
	LD		HL, (TCP.PAYLOAD_LEFT)
	LD		A, H
	OR		L
	JR		NZ, .protocol_open
	CALL	PASSIVE_WAIT_OK
	JR		C, .fail_open
	CALL	ISA.ISA_CLOSE

	LD		HL, (passive_pending)
	LD		DE, (TCP.LAST_IPD_LEN)
	OR		A
	SBC		HL, DE
	JR		C, .protocol
	LD		(passive_pending), HL
	LD		BC, (TCP.RECV_STORED)
	XOR		A
	RET

.protocol_open
	LD		A, RES_ERROR
	SCF
.fail_open
	PUSH	AF
	CALL	ISA.ISA_CLOSE
	POP		AF
	SCF
	RET
.protocol
	LD		A, RES_ERROR
	SCF
	RET
.tx_fail
	LD		A, RES_TX_TIMEOUT
	SCF
	RET

PASSIVE_WAIT_IPD_OR_CLOSE
	LD		IX, TCP.IPD_PREFIX
	LD		IY, TCP.CLOSED_PREFIX
.next
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	LD		E, A
	LD		A, (IX+0)
	CP		E
	JR		NZ, .ipd_reset
	INC		IX
	LD		A, (IX+0)
	OR		A
	JR		Z, .ipd
	JR		.closed_check
.ipd_reset
	LD		IX, TCP.IPD_PREFIX
	LD		A, E
	CP		'+'
	JR		NZ, .closed_check
	INC		IX
.closed_check
	LD		A, (IY+0)
	CP		E
	JR		NZ, .closed_reset
	INC		IY
	LD		A, (IY+0)
	OR		A
	JR		Z, .closed
	JR		.next
.closed_reset
	LD		IY, TCP.CLOSED_PREFIX
	LD		A, E
	CP		'C'
	JR		NZ, .next
	INC		IY
	JR		.next
.ipd
	XOR		A
	RET
.closed
	LD		A, RES_NOT_CONN
	SCF
	RET
.timeout
	LD		A, RES_RS_TIMEOUT
	SCF
	RET

PASSIVE_READ_DEC
	LD		HL, 0
.next
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	CP		','
	JR		Z, .delim
	CP		':'
	JR		Z, .delim
	CP		13
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
	LD		(passive_delim), A
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

PASSIVE_WAIT_DATA_PREFIX
	LD		IX, PASSIVE_DATA_PREFIX
.next
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	LD		E, A
	LD		A, (IX+0)
	CP		E
	JR		NZ, .reset
	INC		IX
	LD		A, (IX+0)
	OR		A
	RET		Z
	JR		.next
.reset
	LD		IX, PASSIVE_DATA_PREFIX
	LD		A, E
	CP		'+'
	JR		NZ, .next
	INC		IX
	JR		.next
.timeout
	LD		A, RES_RS_TIMEOUT
	SCF
	RET

PASSIVE_WAIT_OK
.seek
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	CP		13
	JR		Z, .seek
	CP		10
	JR		Z, .seek
	CP		'O'
	JR		NZ, .error
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	CP		'K'
	JR		NZ, .error
.eol
	CALL	TCP.READ_BYTE_RECV_TIMEOUT_OPEN
	JR		C, .timeout
	CP		10
	JR		NZ, .eol
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

passive_pending	DW 0
passive_delim	DB 0
PASSIVE_DATA_PREFIX DB "+CIPRECVDATA:", 0

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
