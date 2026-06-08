; ======================================================
; FILE - minimal DSS file output (used for binary/media downloads).
; Register conventions match the network kit's WGET and the DSS API:
;   CREATE (#0A): HL=path, A=attr        -> A=handle, CF=1 error
;   WRITE  (#14): A=handle, HL=buf, DE=len -> CF=1 error
;   CLOSE  (#12): A=handle
;   MKDIR  (#1B): HL=path                -> CF=1 (e.g. already exists)
; ======================================================

	MODULE FILE

DSS_CREATE_OVR	EQU 0x0A				; create/overwrite (DSS_CREATE #0A, proven by wget)
NO_HANDLE		EQU 0xFF

; Create the directory whose ASCIIZ path is in HL. Errors (already exists) ignored.
ENSURE_DIR
	LD		C, DSS_MKDIR
	RST		DSS
	RET

; Create/overwrite the file whose ASCIIZ path is in HL.
; Out: CF=0 ok (handle saved in fh), CF=1 error (A=DSS code).
CREATE
	LD		A, FA_ARCHIVE
	LD		C, DSS_CREATE_OVR
	RST		DSS
	RET		C
	LD		(fh), A
	OR		A						; CF=0
	RET

; Write BC bytes from HL to the open file. Out: CF=1 on error.
WRITE
	LD		A, B
	OR		C
	RET		Z						; nothing to write -> CF=0
	LD		D, B
	LD		E, C					; DE = size
	LD		A, (fh)
	LD		C, DSS_WRITE
	RST		DSS						; HL=buf, DE=size, A=handle
	RET

; Close the open file if one is open.
CLOSE
	LD		A, (fh)
	CP		NO_HANDLE
	RET		Z
	LD		C, DSS_CLOSE_FILE
	RST		DSS
	LD		A, NO_HANDLE
	LD		(fh), A
	RET

fh		DB NO_HANDLE

	ENDMODULE
