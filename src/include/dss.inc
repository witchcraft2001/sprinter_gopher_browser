; ======================================================
; Defines for DSS Estex for Sprinter computer
; By Roman Boykov. Copyright (c) 2024
; https://github.com/romychs
; ======================================================

	IFNDEF	_DSS_INC
	DEFINE	_DSS_INC

; DSS RST Entry
DSS                 EQU 0x10

; DSS Functions
DSS_CURDISK         EQU 0x02
DSS_CREATE_FILE     EQU 0x0B
DSS_DELETE          EQU 0x0E
DSS_OPEN_FILE       EQU 0x11
DSS_CLOSE_FILE      EQU 0x12
DSS_READ_FILE       EQU 0x13
DSS_WRITE           EQU 0x14
DSS_MOVE_FP_CP      EQU 0x0115
DSS_MOVE_FP         EQU 0x15			; A=handle B=whence(0/1/2) HL:IX=offset -> HL:IX=pos
SEEK_END            EQU 2
DSS_FIND_FIRST      EQU 0x0119
DSS_FIND_NEXT       EQU 0x011A
DSS_MKDIR           EQU 0x1B
DSS_CHDIR           EQU 0x1D
DSS_CURDIR          EQU 0x1E
DSS_SYSTIME         EQU 0x21
DSS_SETTIME         EQU 0x22
DSS_SCANKEY			EQU 0x31
DSS_ECHOKEY			EQU	0x32
DSS_KCLEAR			EQU 0x35			; clear keyboard buffer
DSS_SETWIN			EQU 0x38
DSS_SETWIN1			EQU 0x39
DSS_SETWIN2			EQU 0x3A
DSS_SETWIN3			EQU 0x3B
DSS_INFOMEM			EQU 0x3C
DSS_GETMEM			EQU 0x3D
DSS_FREEMEM			EQU	0x3E
DSS_SETMEM			EQU DSS_SETWIN			; Backward-compatible alias.
DSS_EXIT            EQU 0x41
; Environment variables (PAGE 2 @ 0xE400), persist across program runs in a
; session. Names are auto-uppercased. Sub-function in B.
DSS_ENVIRON			EQU 0x46
ENV_GET				EQU 0x01				; HL="NAME",0  DE=value buf; A=0xFF found / 0 not
ENV_SET				EQU 0x02				; HL="NAME=VALUE",0  ("NAME=",0 deletes)
; Blocking key read is function 0x30 (per DSS function map). The previous value
; 0x48 is not a defined DSS function, so RST DSS returned immediately and any
; "press a key"/overwrite prompt self-cancelled without waiting for input.
DSS_WAITKEY			EQU 0x30
DSS_SETVMOD			EQU 0x50
DSS_GETVMOD			EQU 0x51
DSS_CLEAR			EQU 0x56
DSS_PUTCHAR			EQU 0x5B
DSS_PCHARS          EQU 0x5C


DSS_VMOD_T40		EQU 0x02							; text 40x32, 16 colors
DSS_VMOD_T80		EQU 0x03							; text 80x32, 16 colors
DSS_VMOD_G320		EQU 0x81							; graphics 320x256, 256 colors
DSS_VMOD_G640		EQU 0x82							; graphics 640x256, 16 colors


; DSS Error codes
E_FILE_EXISTS       EQU 7
E_FILE_NOT_FOUND    EQU 3

; Keyboard Shift key status bits
KB_R_ALT			EQU 0x01
KB_R_CTRL			EQU 0x02
KB_L_ALT			EQU 0x04
KB_L_CTRL			EQU 0x08
KB_ALT				EQU 0x10
KB_CTRL				EQU 0x20
KB_R_SHIFT			EQU 0x40
KB_L_SHIFT			EQU 0x80


; File attributes
FA_READONLY			EQU 0x01
FA_HIDDEN			EQU 0x02
FA_SYSTEM			EQU 0x04
FA_LABEL			EQU 0x08
FA_DIRECTORY		EQU 0x10
FA_ARCHIVE			EQU 0x20

; File Access mode
FM_READ_WRITE		EQU 0x00
FM_READ				EQU 0x01
FM_WRITE			EQU 0x02

	ENDIF 
