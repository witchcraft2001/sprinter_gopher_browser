; ======================================================
; CFG - read & parse GOPHER.CFG (next to the EXE; we chdir there at startup).
;
; INI-style, two sections:
;   [settings]            general options kept in memory (needed during a run)
;   [viewers]             file-type -> program map, "ext=program %file%"
;                         (%file% is replaced with the saved file's path at launch)
; Comments start with '#'/';'; blank lines ignored. Section & ext names compare
; case-insensitively.
;
; The file is STREAMED through STAGE (chunked) and assembled line by line in a
; small WIN2 accumulator, so its size is not bounded by a fixed buffer. We KEEP
; only the [settings] (few, small -> a tiny WIN1 pool). The [viewers] map is NOT
; kept: a lookup re-scans the file on demand and returns the one matching command
; (this is a rare action - opening a just-downloaded file - so re-reading is fine).
;
; Public:
;   CFG.LOAD            parse [settings] at startup. CF=1 if the file is absent.
;   CFG.VIEWER_FOR_EXT  HL=ext ASCIIZ -> DE=command template (CMD_TPL), CF=0; else CF=1.
;   CFG.SETTING         HL=key ASCIIZ -> DE=value, CF=0; CF=1 none.
;   CFG.BUILD_CMD       HL=template, DE=file path -> HL=CMD_BUF ("%file%" expanded)
; ======================================================

	MODULE CFG

ST_MAX			EQU 16					; max kept settings
ST_POOL_SIZE	EQU 256					; bytes of kept setting strings
LINE_MAX		EQU 256					; longest config line (== CFG_LINE region)
EXT_MAX			EQU 16					; longest extension we match
TPL_MAX			EQU 128					; matched viewer command template
CMD_MAX			EQU 192					; built command line (Dss.Exec arg)

MODE_SETTINGS	EQU 0					; LOAD: collect [settings]
MODE_VIEWER		EQU 1					; VIEWER_FOR_EXT: find one [viewers] entry

SEC_NONE		EQU 0
SEC_SETTINGS	EQU 1
SEC_VIEWERS		EQU 2

; ------------------------------------------------------
; Parse [settings] from GOPHER.CFG at startup. Out: CF=1 if absent.
; ------------------------------------------------------
LOAD
	XOR		A
	LD		(st_count), A
	LD		HL, ST_POOL
	LD		(pool_ptr), HL
	LD		A, MODE_SETTINGS
	LD		(cfg_mode), A
	JP		SCAN_FILE

; ------------------------------------------------------
; Look up the program for an extension, on demand. In: HL=ext ASCIIZ.
; Out: CF=0 and DE=command template (in CMD_TPL); CF=1 if none / no file.
; ------------------------------------------------------
VIEWER_FOR_EXT
	LD		DE, look_ext			; remember the wanted ext (HL may be transient)
	LD		B, EXT_MAX
	CALL	MAIN.STRCPYN
	XOR		A
	LD		(vw_found), A
	LD		A, MODE_VIEWER
	LD		(cfg_mode), A
	CALL	SCAN_FILE
	RET		C						; no file -> no viewer
	LD		A, (vw_found)
	OR		A
	JR		Z, .none
	LD		DE, CMD_TPL
	OR		A						; CF=0
	RET
.none
	SCF
	RET

; ------------------------------------------------------
; Stream GOPHER.CFG line by line through PROC_LINE. Out: CF=1 if the file is
; absent (CF=0 otherwise). Uses STAGE as the read buffer; ISA must be closed.
; ------------------------------------------------------
SCAN_FILE
	XOR		A
	LD		(cur_section), A
	LD		HL, CFG_LINE
	LD		(line_wp), HL
	; Open by ABSOLUTE path (EXE dir + name) so it is found regardless of the
	; current directory. EXE_DIR is empty if AppInfo failed -> falls back to a
	; relative open.
	LD		HL, MAIN.EXE_DIR
	LD		DE, cfg_path
	CALL	MAIN.COPYZ
	LD		HL, CFG_NAME
	CALL	MAIN.COPYZ
	XOR		A
	LD		(DE), A
	LD		HL, cfg_path
	LD		A, FM_READ
	LD		C, DSS_OPEN_FILE
	RST		DSS						; -> A=handle, CF=1 not found
	RET		C
	LD		(cfg_fm), A
	LD		B, SEEK_END				; total size drives the chunk loop
	LD		HL, 0
	LD		IX, 0
	LD		C, DSS_MOVE_FP
	RST		DSS						; HL:IX = size (configs are small; use IX low 16)
	PUSH	IX
	POP		HL
	LD		(cfg_rem), HL
	LD		A, (cfg_fm)
	LD		B, 0					; SEEK_SET 0
	LD		HL, 0
	LD		IX, 0
	LD		C, DSS_MOVE_FP
	RST		DSS
.chunk
	LD		HL, (cfg_rem)
	LD		A, H
	OR		L
	JR		Z, .eof
	LD		DE, STAGE_SIZE			; chunk = min(remaining, STAGE_SIZE)
	OR		A
	SBC		HL, DE
	JR		NC, .full
	LD		DE, (cfg_rem)
.full
	PUSH	DE
	LD		HL, STAGE
	LD		A, (cfg_fm)
	LD		C, DSS_READ_FILE
	RST		DSS
	POP		BC						; BC = bytes in STAGE
	LD		HL, (cfg_rem)
	OR		A
	SBC		HL, BC
	LD		(cfg_rem), HL
	LD		HL, STAGE
.feed
	LD		A, B
	OR		C
	JR		Z, .chunk
	LD		A, (HL)
	INC		HL
	DEC		BC
	CP		13
	JR		Z, .feed				; ignore CR
	CP		10
	JR		Z, .nl
	LD		(ch_tmp), A				; append to the line (drop if full)
	PUSH	HL
	LD		HL, (line_wp)
	LD		DE, CFG_LINE + LINE_MAX - 1
	OR		A
	SBC		HL, DE					; CF=1 if room
	POP		HL
	JR		NC, .feed
	LD		DE, (line_wp)
	LD		A, (ch_tmp)
	LD		(DE), A
	INC		DE
	LD		(line_wp), DE
	JR		.feed
.nl
	PUSH	BC
	PUSH	HL
	CALL	FLUSH_LINE
	POP		HL
	POP		BC
	JR		.feed
.eof
	CALL	FLUSH_LINE				; trailing line without a newline
	LD		A, (cfg_fm)
	LD		C, DSS_CLOSE_FILE
	RST		DSS
	OR		A						; CF=0
	RET

; NUL-terminate the line, process it, reset the accumulator.
FLUSH_LINE
	LD		HL, (line_wp)
	LD		(HL), 0
	LD		HL, CFG_LINE
	CALL	PROC_LINE
	LD		HL, CFG_LINE
	LD		(line_wp), HL
	RET

; Process one NUL-terminated line in HL (dispatched by section + cfg_mode).
PROC_LINE
	CALL	SKIP_WS
	LD		A, (HL)
	OR		A
	RET		Z						; blank
	CP		'#'
	RET		Z						; comment
	CP		';'
	RET		Z
	CP		'['
	JR		Z, .section
	; key=value
	PUSH	HL
.findeq
	LD		A, (HL)
	OR		A
	JR		Z, .noeq
	CP		'='
	JR		Z, .goteq
	INC		HL
	JR		.findeq
.noeq
	POP		HL
	RET
.goteq
	LD		(HL), 0					; terminate key
	INC		HL
	CALL	SKIP_WS					; allow "ext = program"
	EX		DE, HL					; DE = value
	POP		HL						; HL = key
	CALL	TRIM_TRAIL
	LD		A, (cur_section)
	CP		SEC_SETTINGS
	JR		Z, .settings
	CP		SEC_VIEWERS
	JR		Z, .viewers
	RET
.settings
	LD		A, (cfg_mode)
	CP		MODE_SETTINGS
	RET		NZ						; only collected during LOAD
	JP		ADD_SETTING
.viewers
	LD		A, (cfg_mode)
	CP		MODE_VIEWER
	RET		NZ						; only searched during a lookup
	PUSH	DE						; value (command)
	LD		DE, look_ext
	CALL	STRCMP_CI				; key(HL) vs wanted ext
	POP		DE
	RET		NZ
	EX		DE, HL					; HL = value (command template)
	LD		DE, CMD_TPL
	LD		B, TPL_MAX
	CALL	MAIN.STRCPYN
	LD		A, 1
	LD		(vw_found), A
	RET
.section
	INC		HL						; past '['
	PUSH	HL
.findrb
	LD		A, (HL)
	OR		A
	JR		Z, .secdone
	CP		']'
	JR		Z, .secend
	INC		HL
	JR		.findrb
.secend
	LD		(HL), 0
.secdone
	POP		HL
	LD		DE, S_SETTINGS
	CALL	STRCMP_CI
	JR		Z, .is_settings
	LD		DE, S_VIEWERS
	CALL	STRCMP_CI
	JR		Z, .is_viewers
	XOR		A
	LD		(cur_section), A
	RET
.is_settings
	LD		A, SEC_SETTINGS
	LD		(cur_section), A
	RET
.is_viewers
	LD		A, SEC_VIEWERS
	LD		(cur_section), A
	RET

; Store a setting: copy key(HL) and value(DE) into ST_POOL, record the pointers.
; Silently dropped if the table or the pool is full.
ADD_SETTING
	LD		A, (st_count)
	CP		ST_MAX
	RET		NC
	LD		(p_val), DE
	CALL	POOL_ADD				; copy key -> DE
	RET		C
	LD		(p_key), DE
	LD		HL, (p_val)
	CALL	POOL_ADD				; copy value -> DE
	RET		C
	LD		(p_val), DE
	LD		A, (st_count)			; st_key[count] = key
	LD		L, A
	LD		H, 0
	ADD		HL, HL
	LD		DE, st_key
	ADD		HL, DE
	LD		DE, (p_key)
	LD		(HL), E
	INC		HL
	LD		(HL), D
	LD		A, (st_count)			; st_val[count] = value
	LD		L, A
	LD		H, 0
	ADD		HL, HL
	LD		DE, st_val
	ADD		HL, DE
	LD		DE, (p_val)
	LD		(HL), E
	INC		HL
	LD		(HL), D
	LD		A, (st_count)
	INC		A
	LD		(st_count), A
	RET

; Copy the ASCIIZ at HL into ST_POOL. Out: DE=its pool address, CF=0; CF=1 (nothing
; copied) if the pool would overflow. Advances pool_ptr.
POOL_ADD
	LD		DE, (pool_ptr)
	PUSH	DE
.c
	LD		A, D					; room: pool_ptr (DE) < ST_POOL + ST_POOL_SIZE
	CP		high (ST_POOL + ST_POOL_SIZE)
	JR		C, .room
	LD		A, E
	CP		low (ST_POOL + ST_POOL_SIZE)
	JR		NC, .oflow
.room
	LD		A, (HL)
	LD		(DE), A
	INC		DE
	OR		A
	JR		Z, .done
	INC		HL
	JR		.c
.done
	LD		(pool_ptr), DE
	POP		DE
	OR		A
	RET
.oflow
	POP		DE
	SCF
	RET

; ------------------------------------------------------
; Lookup a setting value. In: HL=key ASCIIZ. Out: CF=0 and DE=value if found.
; ------------------------------------------------------
SETTING
	LD		A, (st_count)
	OR		A
	JR		Z, .none
	LD		B, A
	LD		C, 0
.l
	LD		(look_key), HL
	LD		A, C
	LD		L, A
	LD		H, 0
	ADD		HL, HL
	LD		DE, st_key
	ADD		HL, DE
	LD		E, (HL)
	INC		HL
	LD		D, (HL)
	LD		HL, (look_key)
	PUSH	BC						; STRCMP_CI trashes B,C
	CALL	STRCMP_CI
	POP		BC
	JR		Z, .hit
	LD		HL, (look_key)
	INC		C
	DJNZ	.l
.none
	SCF
	RET
.hit
	LD		A, C
	LD		L, A
	LD		H, 0
	ADD		HL, HL
	LD		DE, st_val
	ADD		HL, DE
	LD		E, (HL)
	INC		HL
	LD		D, (HL)
	OR		A
	RET

; ------------------------------------------------------
; Build a command line by expanding every "%file%" in the template with the file
; path. In: HL=template ASCIIZ, DE=file path ASCIIZ. Out: HL=CMD_BUF (ASCIIZ).
; ------------------------------------------------------
BUILD_CMD
	LD		(bc_path), DE
	LD		DE, CMD_BUF
	LD		(bc_dst), DE
	LD		BC, CMD_MAX - 1
.l
	LD		A, B
	OR		C
	JR		Z, .done
	LD		A, (HL)
	OR		A
	JR		Z, .done
	CP		'%'
	JR		NZ, .copy
	PUSH	HL
	LD		DE, TOK_FILE
	CALL	MATCH_TOKEN
	JR		C, .nomatch
	POP		AF						; consumed the token
	CALL	EMIT_PATH
	JR		.l
.nomatch
	POP		HL
.copy
	LD		A, (HL)
	CALL	EMIT_CH
	INC		HL
	JR		.l
.done
	LD		HL, (bc_dst)
	LD		(HL), 0
	LD		HL, CMD_BUF
	RET

EMIT_CH
	PUSH	HL
	LD		HL, (bc_dst)
	LD		(HL), A
	INC		HL
	LD		(bc_dst), HL
	POP		HL
	DEC		BC
	RET

EMIT_PATH
	PUSH	HL
	LD		HL, (bc_path)
.pl
	LD		A, B
	OR		C
	JR		Z, .pe
	LD		A, (HL)
	OR		A
	JR		Z, .pe
	CALL	EMIT_CH
	INC		HL
	JR		.pl
.pe
	POP		HL
	RET

; If HL matches the ASCIIZ token at DE, return CF=0 with HL past the token; else
; CF=1, HL unchanged. Preserves BC.
MATCH_TOKEN
	PUSH	HL
	PUSH	BC
.m
	LD		A, (DE)
	OR		A
	JR		Z, .match
	LD		B, A
	LD		A, (HL)
	CP		B
	JR		NZ, .no
	INC		HL
	INC		DE
	JR		.m
.no
	POP		BC
	POP		HL
	SCF
	RET
.match
	POP		BC
	POP		AF
	OR		A
	RET

; ------------------------------------------------------
; String helpers.
; ------------------------------------------------------
SKIP_WS
	LD		A, (HL)
	CP		' '
	JR		Z, .adv
	CP		9
	RET		NZ
.adv
	INC		HL
	JR		SKIP_WS

; NOTE: must preserve DE - callers keep the value pointer there. The body uses DE
; as a work register, so save/restore the caller's DE (and HL) around it.
TRIM_TRAIL
	PUSH	DE
	PUSH	HL
	LD		D, H
	LD		E, L
.t
	LD		A, (HL)
	OR		A
	JR		Z, .end
	CP		' '
	JR		Z, .skip
	CP		9
	JR		Z, .skip
	INC		HL
	LD		D, H
	LD		E, L
	JR		.t
.skip
	INC		HL
	JR		.t
.end
	EX		DE, HL
	LD		(HL), 0
	POP		HL
	POP		DE
	RET

; Case-insensitive ASCIIZ compare. In: HL, DE. Out: ZF=1 if equal. Trashes A,B.
STRCMP_CI
	LD		A, (DE)
	CALL	.up
	LD		B, A
	LD		A, (HL)
	CALL	.up
	CP		B
	RET		NZ
	OR		A
	RET		Z
	INC		HL
	INC		DE
	JR		STRCMP_CI
.up
	CP		'a'
	RET		C
	CP		'z' + 1
	RET		NC
	SUB		0x20
	RET

; ------------------------------------------------------
; Data (WIN1, small now that the viewers map isn't kept).
; ------------------------------------------------------
st_key			DS ST_MAX * 2, 0
st_val			DS ST_MAX * 2, 0
st_count		DB 0
cfg_fm			DB 0
cfg_rem			DW 0
cfg_mode		DB 0
cur_section		DB 0
vw_found		DB 0
ch_tmp			DB 0
line_wp			DW 0
pool_ptr		DW 0
p_key			DW 0
p_val			DW 0
look_key		DW 0
bc_path			DW 0
bc_dst			DW 0
cfg_path		DS 144, 0				; "<EXE dir>GOPHER.CFG" (absolute open path)
look_ext		DS EXT_MAX, 0			; the extension being looked up
CMD_TPL			DS TPL_MAX, 0			; matched viewer command template
ST_POOL			DS ST_POOL_SIZE, 0		; kept setting strings
CMD_BUF			DS CMD_MAX, 0			; built command for Dss.Exec

CFG_NAME		DB "GOPHER.CFG", 0
S_SETTINGS		DB "settings", 0
S_VIEWERS		DB "viewers", 0
TOK_FILE		DB "%file%", 0

	ENDMODULE
