; ======================================================
; Defines for Sprinter computer hardware
; By Roman Boykov. Copyright (c) 2024
; https://github.com/romychs
; ======================================================

	IFNDEF	_SPRINTER
	DEFINE	_SPRINTER

; Memory pages
PAGE0_ADDR          EQU 0x0000
PAGE1_ADDR          EQU 0x4000
PAGE2_ADDR          EQU 0x8000
PAGE3_ADDR          EQU 0xC000

; ----- BIGBUF region (legacy, for utilities still at ORG 0x8100) --------
; Smaller utilities (netup, netprobe, ping, ntp, etc.) still load at
; 0x8100 and put their BSS in 0x8100..0xBFFF. Larger utilities
; (WGET/TFTP/FTP) moved to ORG 0x4100 so code+BSS+stack all live below
; the 0xC000 ISA banking window naturally; they do not need BIGBUF.
; These constants remain only for legacy 0x8100 utilities that may
; later need a big buffer; using them requires confirmation that DSS
; calls don't swap PAGE1 (0x4000..0x7FFF) on the active utility.
BIGBUF_BASE         EQU 0x4100
BIGBUF_END          EQU 0x7E00
BIGBUF_SIZE         EQU BIGBUF_END - BIGBUF_BASE

; Sprinter ports to switch mem pages
PAGE0               EQU 0x82
PAGE1               EQU 0xA2
PAGE2               EQU 0xC2
PAGE3               EQU 0xE2

; CTC Control register ports
CTC_CH0				EQU 0x10
CTC_CH1				EQU 0x11
CTC_CH2				EQU 0x12
CTC_CH3				EQU 0x13

CTC_CR_VEC			EQU 0x01							; 1 - Vector, 0 - Control
CTC_CR_SWR			EQU 0x02							; 1 - Software Reset, 0 - Continued operation
CTC_CR_TCF			EQU 0x04							; 1 - TYime const follows
CTC_CR_TTR			EQU 0x08							; 1 - Time trigger
CTC_CT_TRE			EQU 0x10							; 1 - Trigger Edge
CTC_CT_PRE			EQU 0x20							; 1 - 256 Prescaler, 0 - 16
CTC_CT_CTR			EQU 0x40							; 0 - Timer, 1 - Counter
CTC_CT_EI			EQU 0x80							; Interrupt 1 - enable, 0 - disable

	ENDIF