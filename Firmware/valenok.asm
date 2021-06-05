;	Valenok - Simple and affordable DS18B20-based thermometer in a Gainta G1068G case written in AVR Assembly
;	<https://github.com/FeruzTopalov/valenok/>
;	Copyright (C) 2021 Feruz Topalov
;	Released under the GNU General Public License v3.0 <https://www.gnu.org/licenses/>
;    
;	File: valenok.asm
;	Compiler: AVR Studio 4.19
;	
;	Fuses for AVRDUDESS: LOW:0x7A; HIGH:0xFF (internal RC 9.6 MHz, no clock division)

						

; =============================	Include

.include  "tn13Adef.inc"

; =============================	DS18B20 macroses

	.macro m_pb3_input
		cbi DDRB, PB3
	.endm

	.macro m_pb3_output
		sbi DDRB, PB3
	.endm

	.macro m_pb3_hi
		sbi PORTB, PB3
	.endm

	.macro m_pb3_lo
		cbi PORTB, PB3		
	.endm

; =============================	Power & HC595 control macroses

	.macro m_pow_mr_oe_ctrl_hi
		sbi	PORTB, PB4
	.endm

	.macro m_pow_mr_oe_ctrl_lo
		cbi	PORTB, PB4
	.endm

; =============================	HC595 macroses

	.macro	m_sh_hi
		sbi	PORTB, PB2
	.endm

	.macro	m_sh_lo
		cbi	PORTB, PB2
	.endm

	.macro	m_ds_hi
		sbi	PORTB, PB0
	.endm

	.macro	m_ds_lo
		cbi	PORTB, PB0
	.endm

	.macro	m_st_hi
		sbi	PORTB, PB1
	.endm

	.macro	m_st_lo
		cbi	PORTB, PB1
	.endm

; =============================	Delay macroses

	.macro	set_delay			;set up the time delay amount, from 1 to 7
		subi	@0, (@1 << 5)	;NOTE: THIS shift affects INC macro (below)!
	.endm

	.macro	inc_delay			;bump the delay counter
		subi	@0, -(1 << 5)	;shift value here must be same as above!
	.endm

; =============================	Constants

	.equ symbol_minus = 0x40
	.equ symbol_degree = 0x5A
	.equ symbol_dot = 0x01
	.equ symbol_c = 0xE0
	.equ symbol_r = 0xC0	
	.equ crc_polynom = 0x8C
	.equ config_reg_12bit = 0x7F	

; =============================	DS18B20 Commands

	.equ SKIP_ROM = 0xCC
	.equ CONVERT_T = 0x44
	.equ READ_SCRATCHPAD = 0xBE
	.equ WRITE_SCRATCHPAD = 0x4E
	.equ COPY_SCRATCHPAD = 0x48

; =============================	Registers

	.def count_bytes = R0
	.def count_bits = R1
	.def crc_polynom_calc = R2

	.def fract = R15
	.def temp = R16	

	;R17-R19 - delay routines

	.def ds_byte = R20
	.def i = R21

	.def _r1 = R22 ;Left digit
	.def _r2 = R23 ;Center digit
	.def _r3 = R24 ;Right digit

	.def data = R25	

	;R26-R27 - XH:XL

	.def CRC = R28 		;crc
	.def CRC_next = R29 ;crc next byte

	.def Tlsb = R28		;temperature
	.def Tmsb = R29		;multiple declaration in sake of convenience

	;R30-R31 - ZH:ZL

; =============================	Code segment

	.cseg
	.org 0

; =============================	Interrupts

rjmp START  ; RESET
	reti	; EXT_INT0
	reti    ; PCINT0
	reti    ; TIMER0_OVF
	reti    ; EE_RDY
	reti    ; ANA_COMP
	reti    ; TIMER0_COMPA
	reti    ; TIMER0_COMPA
	reti	; WTD
	reti 	; ADC


; =============================	Program starts here

START:

; =============================	Init stack and ports

	ldi temp, low(RAMEND)
	out SPL, temp
	
	ldi temp, (0<<DDB5)|(1<<DDB4)|(0<<DDB3)|(1<<DDB2)|(1<<DDB1)|(1<<DDB0)	;i/o direction
	out DDRB, temp
	nop

	ldi temp, (0<<PB5)|(0<<PB4)|(0<<PB3)|(0<<PB2)|(0<<PB1)|(0<<PB0)			;level/pull-up
	out PORTB, temp
	nop

; =============================	Clear the HC595 registers

	rcall _delay_100us
	rcall _HC595_store
	rcall _delay_100us

; =============================	Hold the power

	m_pow_mr_oe_ctrl_hi

; =============================	Check the 7-seg indicators

	ldi data, 0xFF
	rcall _HC595_load
	ldi data, 0xFF
	rcall _HC595_load
	ldi data, 0xFF
	rcall _HC595_load
	rcall _HC595_store

	rcall _delay_100ms

	ldi data, 0x00
	rcall _HC595_load
	ldi data, 0x00
	rcall _HC595_load
	ldi data, 0x00
	rcall _HC595_load
	rcall _HC595_store

; ============================= Read the temperature

	rcall _ds_reset
	brtc _to_MAIN			;if sensor is not connected
	rjmp _ds18b20_ok

_to_MAIN:
	rcall _connection_error
	rjmp MAIN

_ds18b20_ok:
	ldi ds_byte, SKIP_ROM
	rcall _ds_write_byte
	rcall _delay_1us

	ldi ds_byte, CONVERT_T
	rcall _ds_write_byte
	rcall _delay_1us

_ds_wait_convertation:
	rcall _ds_read_bit
	rcall _delay_10us
	brsh _ds_wait_convertation

	rcall _ds_reset

	brtc _to_MAIN_2			;if sensor is not connected
	rjmp _ds18b20_ok_2

_to_MAIN_2:
	rcall _connection_error
	rjmp MAIN

_ds18b20_ok_2:
	ldi ds_byte, SKIP_ROM
	rcall _ds_write_byte
	rcall _delay_1us

	ldi ds_byte, READ_SCRATCHPAD
	rcall _ds_write_byte
	rcall _delay_1us

; ============================= Copy sensor's scratchpad into MCU RAM

	ldi XL, Low(SRAM_START)
	ldi XH, High(SRAM_START)

	ldi temp, 9
_read_scratchpad:
	
	rcall _ds_read_byte
	rcall _delay_1us	
	
	st X+, ds_byte

	dec temp
	brne _read_scratchpad

; ============================= Calculate CRC

	ldi temp, crc_polynom
	mov crc_polynom_calc, temp

	ldi XL, Low(SRAM_START)
	ldi XH, High(SRAM_START) 
	ld CRC, X+

	ldi temp, 8
	mov count_bytes, temp
_loop_bytes:
	ld CRC_next, X+

	ldi temp, 8
	mov count_bits, temp
_loop_bits:
	lsr CRC_next
	ror CRC
	brcc _zero
	eor CRC, crc_polynom_calc
_zero:
	dec count_bits
	brne _loop_bits

	dec count_bytes
	brne _loop_bytes

	cpi CRC, 0 
	brne _crc_error
	rjmp _crc_ok

_crc_error:
	ldi data, symbol_c		;"crc" Error message if CRC mismatch
	rcall _HC595_load
	ldi data, symbol_r
	rcall _HC595_load
	ldi data, symbol_c
	rcall _HC595_load
	rcall _HC595_store	
	rjmp MAIN

_crc_ok:					;restore two bytes of the temperature from MCU RAM
	ldi XL, Low(SRAM_START)
	ldi XH, High(SRAM_START) 
	ld Tlsb, X+				;now temterature is here
	ld Tmsb, X

; ============================= Check for 12-bit mode

	ldi XL, Low(SRAM_START + 4)		;points to ds18b20 configuration register
	ldi XH, High(SRAM_START + 4)
	ld temp, X
	cpi temp, config_reg_12bit
	breq _skip_forced_12bit

	rcall _ds_reset

	ldi ds_byte, SKIP_ROM
	rcall _ds_write_byte	

	ldi ds_byte, WRITE_SCRATCHPAD
	rcall _ds_write_byte

	ldi ds_byte, 0x00				;TH & TL registers
	rcall _ds_write_byte
	rcall _ds_write_byte

	ldi ds_byte, config_reg_12bit
	rcall _ds_write_byte
	
	rcall _ds_reset

	ldi ds_byte, SKIP_ROM
	rcall _ds_write_byte

	ldi ds_byte, COPY_SCRATCHPAD
	rcall _ds_write_byte
	
	rcall _delay_100ms

; ============================= Convert temperature format and perform rounding +-0.5 deg C

_skip_forced_12bit:
	mov fract, Tlsb 	;save frac part
	ldi temp, 0x0F
	and fract, temp

	andi Tlsb, 0xF0 	;abs of the temperature
	andi Tmsb, 0x0F
	or Tlsb, Tmsb
	swap Tlsb

	mov temp, Tlsb 		;check for negative
	andi temp, 0x80
	brne _negative_temperature
	ldi Tmsb, 0x00 		;if positive

	mov temp, fract
	cpi temp, 0x08
	brlo _bcd 			;if frac < 0.5 then round down
	inc Tlsb 			;if frac >= 0.5 then round up
	rjmp _bcd

_negative_temperature:
	ldi Tmsb, 0xFF 		;if negative

	mov temp, fract
	cpi temp, 0x08 		;compare frac with 0.5
	brlo _05 			;if frac < 0.5 then convert from two's complement and increent
	com Tlsb 			;if frac >= 0.5 then convert from two's complement

	cpi Tlsb, 0			;check for "negative zero"
	brne _bcd
	ldi Tmsb, 0x00 		;make positive zero

	rjmp _bcd

_05:
	com Tlsb
	inc Tlsb
				
; =============================	Convert ot BCD

_bcd:
	push Tlsb
	ldi _r1, 0
	ldi _r2, 0
	ldi _r3, 0

_100:
	cpi Tlsb, 100
	brlo _10
	subi Tlsb, 100
	inc _r1
	rjmp _100

_10:
	cpi Tlsb, 10
	brlo _1
	subi Tlsb, 10
	inc _r2
	rjmp _10

_1:
	cpi Tlsb, 1
	brlo _end
	subi Tlsb, 1
	inc _r3
	rjmp _1

_end:
	pop Tlsb

; =============================	Prepare 7-seg symbols

	ldi ZL, Low(dat_7seg * 2)
	ldi ZH, High(dat_7seg * 2)

	mov temp, _r3
	add ZL, temp
	ldi temp, 0
	adc ZH, temp
	lpm _r3, Z



	ldi ZL, Low(dat_7seg * 2)
	ldi ZH, High(dat_7seg * 2)

	mov temp, _r2
	add ZL, temp
	ldi temp, 0
	adc ZH, temp
	lpm _r2, Z



	ldi ZL, Low(dat_7seg * 2)
	ldi ZH, High(dat_7seg * 2)

	mov temp, _r1
	add ZL, temp
	ldi temp, 0
	adc ZH, temp
	lpm _r1, Z

; =============================	Apply "deg" / "minus" symbols, trim trailing zeros

	cpi Tlsb, 10
	brsh _to_100
	cpi Tmsb, 0
	brne _neg_10
;positive temperature under 10 deg
	mov _r2, _r3
	ldi _r3, symbol_degree
	ldi _r1, 0
	rjmp _display
_neg_10:
;negative temperature above -10
	mov _r2, _r3
	ldi _r3, symbol_degree
	ldi _r1, symbol_minus		
	rjmp _display

_to_100:
	cpi Tlsb, 100
	brsh _display	
	cpi Tmsb, 0
	brne _neg_100
;positive temperature under 100 deg
	mov _r1, _r2
	mov _r2, _r3
	ldi _r3, symbol_degree
	rjmp _display
_neg_100:
;negative temperature above -55
	ldi _r1, 0x40		
	rjmp _display

; =============================	Shift data to the indicator

_display:
	mov data, _r1
	rcall _HC595_load

	mov data, _r2
	rcall _HC595_load

	mov data, _r3
	rcall _HC595_load

	rcall _HC595_store

; =============================	Hold the result on the indicator for the human reading

MAIN:
	rcall _delay_3s

	ldi data, 0x00
	rcall _HC595_load
	ldi data, 0x00
	rcall _HC595_load
	ldi data, 0x00
	rcall _HC595_load
	rcall _HC595_store

; =============================	Release the power

	m_pow_mr_oe_ctrl_lo

_loop:
	rjmp _loop

; =============================	DS18B20 sensor routines

_ds_reset:	;Reset

	;check the line for short-circuit to the GND
	m_pb3_input
	clt
	sbis PINB, PB3
	ret

	m_pb3_lo
	m_pb3_output

	rcall _delay_100us
	rcall _delay_100us
	rcall _delay_100us
	rcall _delay_100us
	rcall _delay_100us

	m_pb3_input

	rcall _delay_100us

	clt
	sbis PINB, PB3
	set

	;if flag T = 1 - sensor is connected
	;if flag T = 0 - sensor is not connected, or line is shorted to the GND

	rcall _delay_100us
	rcall _delay_100us
	rcall _delay_100us
		
	ret

; =============================

_ds_write_bit:	;Write one bit

	m_pb3_lo
	m_pb3_output

	brcc _write_0

	rcall _delay_1us
	m_pb3_input
	rcall _delay_100us

	ret

_write_0:

	rcall _delay_100us
	m_pb3_input

	ret

; =============================

_ds_write_byte:	;Write one byte

	ldi i, 8

_write_loop:
	ror ds_byte
	rcall _ds_write_bit
	dec i
	brne _write_loop

	ret	

; =============================

_ds_read_bit:	;Read one bit
	
	m_pb3_lo
	m_pb3_output

	rcall _delay_1us

	m_pb3_input

	rcall _delay_10us

	clc
	sbic PINB, PB3
	sec

	rcall _delay_100us	

	ret

; =============================

_ds_read_byte:	;Read one byte
	
	ldi i, 8

_read_loop:
	rcall _ds_read_bit
	ror ds_byte
	dec i
	brne _read_loop

	ret

; =============================	HC595 register routines

_HC595_load:	;Load byte
	m_st_lo
	m_sh_lo
	m_ds_lo

	ldi i, 8

_hc595_loop:
	lsl data

	brcc _m_ds_lo
	m_ds_hi
	rjmp _ds_done

_m_ds_lo:
	m_ds_lo
	nop

_ds_done:
	m_sh_lo

	set_delay temp, 2

_time_hi:
	inc_delay temp
	brcs _time_hi

	m_sh_hi

	set_delay temp, 2

_time_lo:
	inc_delay temp
	brcs _time_lo

	dec i
	brne _hc595_loop
	m_sh_lo
	m_ds_lo
	
	ret

; =============================

_HC595_store:	;Store byte

	m_st_hi
	set_delay temp, 2
_m_st_hi:
	inc_delay temp
	brcs _m_st_hi	
	m_st_lo

	ret

; ============================= "---" Error message if sensor is not connected

_connection_error:
	ldi data, symbol_minus    
	rcall _HC595_load
	ldi data, symbol_minus
	rcall _HC595_load
	ldi data, symbol_minus
	rcall _HC595_load
	rcall _HC595_store	
	ret

; ============================= Delay routines 

_delay_100us:
; ============================= 
;    delay loop generator 
;     960 cycles:
; ----------------------------- 
; delaying 957 cycles:
          ldi  R17, $0B
WGLOOP0:  ldi  R18, $1C
WGLOOP1:  dec  R18
          brne WGLOOP1
          dec  R17
          brne WGLOOP0
; ----------------------------- 
; delaying 3 cycles:
          ldi  R17, $01
WGLOOP2:  dec  R17
          brne WGLOOP2
; ============================= 
	ret



_delay_10us:
; ============================= 
;    delay loop generator 
;     96 cycles:
; ----------------------------- 
; delaying 96 cycles:
          ldi  R17, $20
WGLOOP3:  dec  R17
          brne WGLOOP3
; ============================= 
	ret



_delay_1us:
; ============================= 
;    delay loop generator 
;     10 cycles:
; ----------------------------- 
; delaying 9 cycles:
          ldi  R17, $03
WGLOOP4:  dec  R17
          brne WGLOOP4
; ----------------------------- 
; delaying 1 cycle:
          nop
; ============================= 
	ret



_delay_3s:
; ============================= 
;    delay loop generator 
;     28800000 cycles:
; ----------------------------- 
; delaying 28799955 cycles:
          ldi  R17, $99
WGLOOP5:  ldi  R18, $F8
WGLOOP6:  ldi  R19, $FC
WGLOOP7:  dec  R19
          brne WGLOOP7
          dec  R18
          brne WGLOOP6
          dec  R17
          brne WGLOOP5
; ----------------------------- 
; delaying 45 cycles:
          ldi  R17, $0F
WGLOOP8:  dec  R17
          brne WGLOOP8
; ============================= 
	ret



_delay_100ms:
; ============================= 
;    delay loop generator 
;     960000 cycles:
; ----------------------------- 
; delaying 959928 cycles:
          ldi  R17, $08
WGLOOP9:  ldi  R18, $C6
WGLOOP10:  ldi  R19, $C9
WGLOOP11:  dec  R19
          brne WGLOOP11
          dec  R18
          brne WGLOOP10
          dec  R17
          brne WGLOOP9
; ----------------------------- 
; delaying 72 cycles:
          ldi  R17, $18
WGLOOP12:  dec  R17
          brne WGLOOP12
; ============================= 
	ret


; ============================= 7-seg symbols
;
;					0		1		2		3		4		5		6		7		8		9
dat_7seg:	.db 	0xBE, 	0x06, 	0xEA, 	0x6E, 	0x56, 	0x7C, 	0xFC, 	0x0E, 	0xFE, 	0x7E
