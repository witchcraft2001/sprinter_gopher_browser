; ======================================================
; NET - network HAL, backed by the generic UNETLD selector/loader.
;
; UNETLD reads NET and loads UNET<TAG>.DLL (WIFI is the compatibility alias
; for UNETESP.DLL). The browser keeps this facade stable so the document,
; history and download code do not know which card is active.
; ======================================================

	INCLUDE "unetld.asm"

	MODULE NET

; Local result codes (returned in A when CF=1), distinct from the UNET
; NERR_* range (0..15), so callers can distinguish loader/dispatch failures.
NERR_DLL_LOAD		EQU 32
NERR_DLL_ABI		EQU 33
NERR_DLL_CALL		EQU 34
NERR_NOCONFIG		EQU 35
NERR_SHORT_SEND	EQU 36

NET_ERRBUF_SIZE		EQU 128
; LAST_ERROR is diagnostic-only and is not used during an active transfer;
; keep its destination in WIN2, outside the DLL's WIN1 window.
NET_ERRBUF		EQU DL_BUF

; Latched whenever a UNET call reports NERR_CANCEL. Callers clear it before
; starting a fetch/download and use it to classify an interrupted operation.
net_cancelled		DB 0

; ------------------------------------------------------
; Bring the network layer up. The first call selects and loads the DLL,
; validates ABI/capabilities, and applies CANCELKEYS. Every call then starts
; (or restarts) the backend session with NETSTART. The DLL remains loaded
; until SHUTDOWN so INVALIDATE_NET can recover cheaply.
; ------------------------------------------------------
INIT
	LD		A, (UNETLD.FLAGS)
	BIT		0, A					; UNETLD_F_LOADED
	JR		NZ, .have_dll
	CALL	UNETLD.SELECT
	JR		C, .select_fail
	LD		A, 1					; target window 1
	CALL	UNETLD.LOAD
	JR		C, .load_fail
	LD		DE, UNET_CAP_TCP			; Gopher requires TCP client support
	CALL	UNETLD.REQUIRE
	JR		C, .cap_fail
	LD		A, UNET_OPT_CANCELKEYS
	LD		DE, 1
	LD		B, UNET_FN_SETOPT
	CALL	CALL_UNET				; best-effort; backend may ignore it
	JR		.start
.have_dll
	; Drop a stale session left by a local child or a long local-page idle.
	XOR		A
	LD		B, UNET_FN_NETDONE
	CALL	CALL_UNET				; best-effort
.start
	CALL	UNETLD.NETSTART
	JR		C, .start_fail
	OR		A
	RET		Z
.start_fail
	; UNETLD keeps the backend status in LAST_STATUS. A dispatcher failure
	; has no UNET status and is mapped to the facade's local code.
	CP		UNETLD_E_CALL
	JR		Z, .dll_call
	LD		A, (UNETLD.LAST_STATUS)
	SCF
	RET
.dll_call
	LD		A, NERR_DLL_CALL
	SCF
	RET
.select_fail
	LD		A, NERR_NOCONFIG
	SCF
	RET
.load_fail
	; UNETLD.LOAD leaves a handle open for every error except E_LOAD.
	PUSH	AF
	CALL	UNETLD.UNLOAD
	POP	AF
	CP		UNETLD_E_LOAD
	JR		Z, .load_code
	CP		UNETLD_E_ABI
	JR		Z, .abi_code
	CP		UNETLD_E_NAME
	JR		Z, .abi_code
	LD		A, NERR_DLL_CALL
	SCF
	RET
.load_code
	LD		A, NERR_DLL_LOAD
	SCF
	RET
.abi_code
	LD		A, NERR_DLL_ABI
	SCF
	RET
.cap_fail
	CALL	UNETLD.UNLOAD
	LD		A, NERR_DLL_ABI
	SCF
	RET

; Fast environment-only check for the status bar. SELECT accepts any valid
; generic tag (not just WIFI/RTL) and never touches a DLL or hardware.
CHECK_NET_UP
	PUSH	HL
	CALL	UNETLD.SELECT
	JR		NC, .configured
	LD		A, NERR_NOCONFIG
	SCF
	JR		.done
.configured
	OR		A					; explicit CF=0
.done
	POP		HL
	RET

; In: HL=host ASCIIZ, DE=port ASCIIZ. Out: CF=0 connected; CF=1, A=result.
CONNECT
	PUSH	DE
	EX		DE, HL					; DE = host
	POP		IX					; IX = port
	XOR		A					; channel 0
	LD		B, UNET_FN_CONNECT
	CALL	CALL_UNET
	RET		C
	OR		A
	RET		Z
	SCF
	RET

; In: HL=buffer, BC=len. Out: CF=0 when the whole buffer was confirmed sent.
SEND
	LD		(send_len), BC
	PUSH	BC
	POP		IX					; IX = length
	EX		DE, HL					; DE = buffer
	XOR		A					; channel 0
	LD		B, UNET_FN_SEND
	CALL	CALL_UNET
	RET		C
	OR		A
	JR		NZ, .fail
	LD		HL, (send_len)
	OR		A
	SBC		HL, DE					; DE = bytes sent
	RET		Z
	LD		A, NERR_SHORT_SEND
.fail
	SCF
	RET
send_len	DW 0

; In: HL=dest, BC=max, DE=timeout_ms. Out: CF=0, A=0|NERR_CLOSED, BC=received.
NERR_RXLOST		EQU 37
RECV
	PUSH	DE
	EX		DE, HL					; DE = destination
	PUSH	BC
	POP		IX					; IX = maximum
	POP		IY					; IY = timeout
	XOR		A					; channel 0
	LD		B, UNET_FN_RECV
	CALL	CALL_UNET
	RET		C
	CP		NERR_CANCEL
	JR		Z, .cancel
	PUSH	IX
	POP		HL
	BIT		2, L					; UNET_RXF_LOST
	JR		NZ, .lost
	CP		NERR_OK
	JR		Z, .ok
	CP		NERR_CLOSED
	JR		Z, .ok					; trailing bytes remain valid
	SCF
	RET
.ok
	LD		B, D
	LD		C, E
	OR		A
	RET
.cancel
	LD		A, NERR_CANCEL
	SCF
	RET
.lost
	LD		A, NERR_RXLOST
	SCF
	RET

; Close the active channel. Idempotent when no DLL has been loaded.
CLOSE
	LD		A, (UNETLD.FLAGS)
	BIT		0, A
	RET		Z
	XOR		A
	LD		B, UNET_FN_CLOSE
	CALL	CALL_UNET
	RET		C
	OR		A
	RET		Z
	SCF
	RET

; Hand the network back at program exit. UNLOAD is idempotent and also
; releases a DLL after a partially failed initialisation.
SHUTDOWN
	CALL	UNETLD.UNLOAD
	XOR		A
	LD		(net_cancelled), A
	RET

; Hardware RX flow control, gated by the selected DLL's capability mask.
RX_PAUSE
	LD		A, (UNETLD.CAPS + 1)
	AND		HIGH UNET_CAP_RXFLOW
	RET		Z
	XOR		A
	LD		B, UNET_FN_RXPAUSE
	CALL	CALL_UNET
	RET		C
	OR		A
	RET		Z
	SCF
	RET
RX_RESUME
	LD		A, (UNETLD.CAPS + 1)
	AND		HIGH UNET_CAP_RXFLOW
	RET		Z
	XOR		A
	LD		B, UNET_FN_RXRESUME
	CALL	CALL_UNET
	RET		C
	OR		A
	RET		Z
	SCF
	RET

; Fetch the DLL's diagnostic tail into the shared WIN2 receive buffer.
LAST_ERROR
	LD		DE, NET_ERRBUF
	LD		IX, NET_ERRBUF_SIZE
	XOR		A
	LD		B, UNET_FN_LASTERR
	CALL	CALL_UNET
	RET		C
	XOR		A
	RET

; In: B = UNET function number; A/DE/IX/IY = function arguments.
; Out: CF=0, A=UNET status; CF=1, A=NERR_DLL_CALL on dispatcher failure.
CALL_UNET
	EI							; DLL waits require interrupts enabled
	CALL	UNETLD.CALL
	JR		C, .dispatch_fail
	CP		NERR_CANCEL
	JR		NZ, .done
	LD		(net_cancelled), A
.done
	OR		A					; CP above must not leak CF to callers
	RET
.dispatch_fail
	LD		A, NERR_DLL_CALL
	SCF
	RET

	ENDMODULE
