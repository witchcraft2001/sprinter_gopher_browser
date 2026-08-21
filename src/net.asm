; ======================================================
; NET - network HAL, v0.2.0: runtime UNET-ABI DLL (UNETESP.DLL / UNETRTL.DLL)
; loaded via libman instead of a statically-linked ESP-AT kit. The backend is
; chosen at runtime by the env var NET (WIFI -> UNETESP.DLL, RTL ->
; UNETRTL.DLL), exactly like sources/weather-forecast and sources/ftpclient.
;
; Window discipline: the DLL is loaded into WIN1 (l_load A=1) - WIN1 holds all
; of gopher's own code, but it is displaced only for the narrow span inside a
; single l_call/l_load, and libman restores it (raw OUT of the saved physical
; page) before returning - see console.inc's LIBMAN_W2_BASE comment. libman
; itself (the thing actually executing while WIN1 is displaced) is therefore
; WIN2-resident: LIBMAN_STORE, assembled via a DISP block in main.asm, is
; LDIR'd to LIBMAN_W2_BASE once at startup.
; ======================================================

	INCLUDE "unet.inc"

	MODULE NET

; Local result codes (returned in A when CF=1), distinct from the UNET
; NERR_* range (0..15) so callers can tell a libman/config-level failure
; apart from a UNET-level one.
NERR_DLL_LOAD		EQU 32		; libman could not load the DLL (see LIBMAN.l_reason)
NERR_DLL_ABI		EQU 33		; DLL loaded but ABI major/caps are incompatible
NERR_DLL_CALL		EQU 34		; libman dispatch failure (bad handle/window)
NERR_NOCONFIG		EQU 35		; env NET missing/not WIFI or RTL
NERR_SHORT_SEND	EQU 36		; DLL confirmed fewer bytes sent than requested

; INIT failure stages, recorded in init_stage and shown by DIAG_TEXT. A bring-up
; failure is otherwise indistinguishable from the outside ("init failed" covers
; a missing DLL, an ABI mismatch and a dead link alike), so the status bar gets
; the stage plus libman's own reason/DSS-error breadcrumbs.
IST_ENV			EQU 1		; env NET unset or not WIFI/RTL
IST_LOAD		EQU 2		; LIBMAN.l_load failed (see lr/ls/dss in DIAG_TEXT)
IST_GETCAPS		EQU 3		; GETCAPS dispatch/status failure
IST_ABI			EQU 4		; ABI major mismatch (code = the major byte seen)
IST_CAPS		EQU 5		; no UNET_CAP_TCP (code = caps low byte seen)
IST_STATUS		EQU 6		; STATUS(0xFF) env probe failed
IST_NETINIT		EQU 7		; NETINIT failed (link/hardware not up)

init_stage			DB 0		; IST_* of the last INIT failure
init_code			DB 0		; result code that accompanied it

dll_handle			DW 0
dll_loaded			DB 0		; DLL loaded into WIN1 (stays loaded until SHUTDOWN)
net_caps			DW 0		; cached GETCAPS bitmask (valid once dll_loaded=1)

NET_ERRBUF_SIZE		EQU 128
NET_ERRBUF			DS NET_ERRBUF_SIZE, 0

; Latched whenever any UNET call returns NERR_CANCEL (SETOPT CANCELKEYS=1
; makes the DLL poll Esc/Ctrl+Z during its own blocking UART waits, same as
; the old kit's WCOMMON.CANCELLED). Callers clear it before starting a fetch
; or download and read it to tell a cancel apart from other failures.
net_cancelled		DB 0

; ------------------------------------------------------
; Bring the network layer up. First call for a process loads the DLL,
; validates its ABI/caps, and applies SETOPT/STATUS; every call (cached or
; not) then does a best-effort NETDONE followed by NETINIT, so a session left
; stale by INVALIDATE_NET (net_inited=0, dll_loaded still 1) recovers without
; a full reload. Out: CF=0 ok; CF=1, A=result code.
; ------------------------------------------------------
INIT
	XOR		A
	LD		(init_stage), A
	LD		(init_code), A
	LD		A, (dll_loaded)
	OR		A
	JR		NZ, .have_dll
	CALL	SELECT_DLL				; -> HL=DLL filename; CF=1/A=NERR_NOCONFIG
	JR		NC, .got_name
	LD		B, IST_ENV
	JR		.fail
.got_name
	LD		A, 1					; target window 1
	CALL	LIBMAN.l_load
	JR		NC, .loaded
	LD		A, NERR_DLL_LOAD		; libman's own l_reason/l_dss_error say why
	LD		B, IST_LOAD
	JR		.fail
.loaded
	LD		(dll_handle), HL
	LD		A, 1
	LD		(dll_loaded), A
	XOR		A
	LD		B, UNET_FN_GETCAPS
	CALL	CALL_UNET
	JR		C, .caps_fail
	OR		A
	JR		NZ, .caps_fail
	LD		(net_caps), DE
	BIT		0, E					; UNET_CAP_TCP - gopher is useless without it
	JR		NZ, .have_tcp
	LD		A, E					; report the caps low byte we actually saw
	LD		B, IST_CAPS
	JR		.unload
.have_tcp
	PUSH	IX
	POP		HL
	LD		A, H
	CP		HIGH UNET_ABI_VERSION
	JR		Z, .abi_ok
	LD		B, IST_ABI				; A = the ABI major byte we saw
	JR		.unload
.abi_ok
	LD		A, UNET_OPT_CANCELKEYS
	LD		DE, 1
	LD		B, UNET_FN_SETOPT
	CALL	CALL_UNET				; best-effort; ignore result
	LD		A, 0xFF					; STATUS(0xFF): env-only probe, no hardware
	LD		B, UNET_FN_STATUS
	CALL	CALL_UNET
	JR		C, .status_fail
	CP		NERR_OK
	JR		Z, .have_dll
	CP		NERR_NONET
	JR		Z, .have_dll
.status_fail
	LD		B, IST_STATUS
	JR		.fail
.have_dll
	XOR		A
	LD		B, UNET_FN_NETDONE
	CALL	CALL_UNET				; best-effort; ignore result
	XOR		A
	LD		B, UNET_FN_NETINIT
	CALL	CALL_UNET
	JR		C, .netinit_fail
	OR		A
	RET		Z
.netinit_fail
	LD		B, IST_NETINIT
.fail
	; In: A = result code, B = stage. Records both and returns CF=1, A=code.
	LD		(init_code), A
	LD		A, B
	LD		(init_stage), A
	LD		A, (init_code)
	SCF
	RET
.caps_fail
	LD		B, IST_GETCAPS
.unload
	; An unusable DLL must not stay resident: free it so a later retry (after
	; the user fixes the setup) starts from a clean l_load.
	LD		(init_code), A
	LD		A, B
	LD		(init_stage), A
	LD		HL, (dll_handle)
	CALL	LIBMAN.l_free
	XOR		A
	LD		(dll_loaded), A
	LD		A, NERR_DLL_ABI
	SCF
	RET

; Read env NET (WIFI/RTL) and map it to a DLL filename. Out: CF=0, HL=name;
; CF=1, A=NERR_NOCONFIG. No hardware/DLL access - safe as a cheap UI probe.
SELECT_DLL
	LD		HL, env_key_net
	LD		DE, env_val
	LD		B, ENV_GET
	LD		C, DSS_ENVIRON
	RST		DSS
	OR		A
	JR		Z, .noconfig
	LD		HL, env_val
	LD		DE, str_wifi
	CALL	STREQ
	JR		Z, .wifi
	LD		HL, env_val
	LD		DE, str_rtl
	CALL	STREQ
	JR		Z, .rtl
.noconfig
	LD		A, NERR_NOCONFIG
	SCF
	RET
.wifi
	LD		HL, dll_esp
	OR		A
	RET
.rtl
	LD		HL, dll_rtl
	OR		A
	RET

; Fast env-only check for the status bar (no DLL/hardware access). CF=0 if
; env NET selects a recognised backend.
CHECK_NET_UP
	PUSH	HL
	CALL	SELECT_DLL
	POP		HL
	RET

; In: HL=host ASCIIZ, DE=port ASCIIZ. Out: CF=0 connected; CF=1, A=result.
CONNECT
	PUSH	DE
	EX		DE, HL					; DE = host
	POP		IX						; IX = port
	XOR		A						; channel 0
	LD		B, UNET_FN_CONNECT
	CALL	CALL_UNET
	RET		C
	OR		A
	RET		Z
	SCF
	RET

; In: HL=buffer, BC=len. Out: CF=0 the whole buffer was confirmed sent;
; CF=1, A=result (a short send is reported as NERR_SHORT_SEND).
SEND
	LD		(send_len), BC
	PUSH	BC
	POP		IX						; IX = length
	EX		DE, HL					; DE = buffer
	XOR		A						; channel 0
	LD		B, UNET_FN_SEND
	CALL	CALL_UNET
	RET		C
	OR		A
	JR		NZ, .fail
	LD		HL, (send_len)
	OR		A
	SBC		HL, DE					; DE = bytes sent (from the DLL)
	RET		Z						; equal -> CF=0
	LD		A, NERR_SHORT_SEND
.fail
	SCF
	RET
send_len	DW 0

; In: HL=dest, BC=max, DE=timeout_ms. Out: CF=0, A=0|NERR_CLOSED, BC=received
; (trailing bytes on a close are included and must be consumed); CF=1,
; A=NERR_CANCEL / NERR_RXLOST(local, see below) / a dispatch failure, or a
; UNET-level error that should not occur mid-stream.
NERR_RXLOST			EQU 37		; local: UNET_RXF_LOST was set on the reply
RECV
	PUSH	DE						; timeout_ms
	EX		DE, HL					; DE = dest buffer
	PUSH	BC
	POP		IX						; IX = max
	POP		IY						; IY = timeout_ms
	XOR		A						; channel 0
	LD		B, UNET_FN_RECV
	CALL	CALL_UNET
	RET		C
	CP		NERR_CANCEL				; a user cancel outranks the LOST flag (the
	JR		Z, .cancel				; flags reply may be stale on an error return)
	PUSH	IX
	POP		HL
	BIT		2, L					; UNET_RXF_LOST
	JR		NZ, .lost
	CP		NERR_OK
	JR		Z, .ok
	CP		NERR_CLOSED
	JR		Z, .ok					; DE trailing bytes are valid on close too
	SCF							; unexpected UNET-level error mid-stream
	RET
.ok
	LD		B, D
	LD		C, E					; BC = received length
	OR		A						; CF=0, A already 0 or NERR_CLOSED
	RET
.cancel
	LD		A, NERR_CANCEL
	SCF
	RET
.lost
	LD		A, NERR_RXLOST
	SCF
	RET

; Close the active channel. Idempotent; a no-op (CF=0) if the DLL was never
; loaded this run.
CLOSE
	LD		A, (dll_loaded)
	OR		A
	RET		Z
	XOR		A
	LD		B, UNET_FN_CLOSE
	CALL	CALL_UNET
	RET		C
	OR		A
	RET		Z
	SCF
	RET

; Hand the network back at program exit: NETDONE (best-effort) + l_free the
; DLL. Call only if the DLL was ever loaded this run (main.asm's net_inited).
SHUTDOWN
	LD		A, (dll_loaded)
	OR		A
	RET		Z
	XOR		A
	LD		B, UNET_FN_NETDONE
	CALL	CALL_UNET				; best-effort; ignore result
	LD		HL, (dll_handle)
	CALL	LIBMAN.l_free
	XOR		A
	LD		(dll_loaded), A
	RET

; Hardware RX flow control (fn 13/14), only meaningful when the backend
; advertises UNET_CAP_RXFLOW; a no-op (CF=0) otherwise.
RX_PAUSE
	LD		A, (net_caps + 1)
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
	LD		A, (net_caps + 1)
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

; Fetch the DLL's last diagnostic tail into NET_ERRBUF (NUL-terminated, may
; be empty). Out: CF=0 filled (possibly empty); CF=1 on a dispatch failure.
LAST_ERROR
	LD		DE, NET_ERRBUF
	LD		IX, NET_ERRBUF_SIZE
	XOR		A
	LD		B, UNET_FN_LASTERR
	CALL	CALL_UNET
	RET		C
	XOR		A
	RET

; In: B = UNET function number; A/DE/IX/IY = that function's arguments.
; Out: CF=0, A = UNET NERR_* status; CF=1, A=NERR_DLL_CALL (libman dispatch
; failure - bad handle/window, not a UNET-level error).
;
; CF is the whole contract here, so the success path must clear it EXPLICITLY:
; the CP below sets CF for every status under NERR_CANCEL (NERR_OK included),
; and every caller tests CF first. Returning that borrow made a successful DLL
; call indistinguishable from a dispatch failure.
CALL_UNET
	EI								; a DLL call entered with interrupts off
									; can hang (mirrors ftpclient's ede8c46 fix)
	LD		HL, (dll_handle)
	CALL	LIBMAN.l_call
	JR		C, .dispatch_fail
	CP		NERR_CANCEL
	JR		NZ, .done
	LD		(net_cancelled), A		; A=NERR_CANCEL (nonzero) -> latch it
.done
	OR		A						; CF=0, A preserved (see above)
	RET
.dispatch_fail
	LD		A, NERR_DLL_CALL
	SCF
	RET

; Append a compact breadcrumb tail for the last INIT failure to the ASCIIZ
; buffer HL points into: " st=<stage> e=<code> lr=<libman reason> ls=<libman
; load stage> dss=<DSS error> is=<DLL INIT status>". Writes at most 40 bytes.
; In: HL = destination (where the NUL should go). Out: buffer NUL-terminated.
DIAG_TEXT
	EX		DE, HL					; DE = write cursor
	LD		HL, diag_tbl
.next
	LD		A, (HL)
	OR		A
	JR		Z, .done
.label
	LD		A, (HL)
	INC		HL
	OR		A
	JR		Z, .value
	LD		(DE), A
	INC		DE
	JR		.label
.value
	LD		C, (HL)
	INC		HL
	LD		B, (HL)
	INC		HL						; BC = address of the byte to print
	PUSH	HL
	LD		A, (BC)
	LD		L, A
	LD		H, 0
	CALL	UTIL.UTOA				; HL=value, DE=dest -> DE past the written NUL
	DEC		DE						; step back onto it: the next label overwrites it
	POP		HL
	JR		.next
.done
	XOR		A
	LD		(DE), A
	RET

; label (ASCIIZ) + address of the byte to print after it; 0 ends the table.
; The LIBMAN.* fields resolve to their WIN2 run addresses (libman is assembled
; via the DISP block in main.asm), which is where they actually live at runtime.
diag_tbl
	DB " st=", 0
	DW init_stage
	DB " e=", 0
	DW init_code
	DB " lr=", 0
	DW LIBMAN.l_reason
	DB " ls=", 0
	DW LIBMAN.l_load_stage
	DB " dss=", 0
	DW LIBMAN.l_dss_error
	DB " is=", 0
	DW LIBMAN.l_init_status
	DB 0

; Compare ASCIIZ at HL and DE. Out: ZF=1 if equal. Trashes A, HL, DE.
STREQ
	LD		A, (DE)
	CP		(HL)
	RET		NZ
	OR		A
	RET		Z
	INC		HL
	INC		DE
	JR		STREQ

env_key_net		DB "NET", 0
; DSS ENV_GET has no destination-capacity argument, and ENV_SET allows a
; NAME=VALUE string up to 255 bytes - so the value buffer must hold 256 bytes
; or an oversized NET value would overrun it. Overlaid on DL_BUF: env NET is
; only ever read outside a transfer (INIT before CONNECT; CHECK_NET_UP from
; the home-page status redraw), when DL_BUF holds nothing live.
env_val			EQU DL_BUF
str_wifi		DB "WIFI", 0
str_rtl			DB "RTL", 0
dll_esp			DB "UNETESP.DLL", 0
dll_rtl			DB "UNETRTL.DLL", 0

	ENDMODULE
