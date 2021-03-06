
;--- 16 bit low-level ASM part of Jemm
;--- to be assembled with JWasm or Masm v6.1+

	.286
	.SEQ		;avoid DOSSEG segment order (RSEG must be first)
	option casemap:none
	option proc:private

	include jemm.inc
	include jemm16.inc
	include debug.inc

?KNOWNGDT equ 0		;is location of GDT known?

?ADDCONT equ 0		; currently not used

;--- interrupt hook list entry 

INTMOD struct
bInt	db ?
wNew	dw ?
wOld	dw ?
INTMOD ends

;--- @DefineBP: macro to define a v86-"breakpoint"

@DefineBP macro _name
_name&::
	@BPOPC
	endm

CStr macro text:VARARG
local sym
CONST segment
sym db text
CONST ends
	exitm <offset sym>
	endm

if ?RSEG
RSEG SEGMENT PARA public 'CODE' ;resident code + data
RSEG ENDS
_TEXT segment word public 'CODE'
_TEXT ends
_TEXT16 GROUP RSEG
else
_TEXT segment PARA public 'CODE'
_TEXT ends
endif

_TEXT32 SEGMENT PARA public 'CODE'  ;include external module Jemm32
if 0 ;JWasm allows to include binary data directly
	incbin <jemm32.bin>, 200h
else
	.nolist
	include _jemm32.inc
	.list
endif
_TEXT32 ENDS

BEGDATA segment PARA public 'DATA'  ;make sure DGROUP is para aligned
BEGDATA ends

_DATA segment word public 'DATA'

ife ?KNOWNGDT
tmpgdt label dword
    dq 0
    dw -1,0,9A00h,00CFh
    dw -1,0,9200h,00CFh
endif

wLow    dw RSEG_END     ;resident low memory required by driver

;--- _brptab is the second of two parameters for Jemm32 init
;--- the entries are offsets in RSEG
;--- the most important one is the offset to the v86 breakpoint table

if ?HOOK13
_brptab RSOFS < RSEG_END, bptable, bRFlags >
else
_brptab RSOFS < RSEG_END, bptable >
endif

if 0;?A20PORTS
wBiosA20    DW 1+2  ;default: trap both kbdc + ps2 ports
endif

_DATA ends

CONST segment word public 'CONST'
intvecs label INTMOD
	INTMOD <15h,offset NEW15, offset OLDINT15>
if ?INTEGRATED
	INTMOD <2Fh,offset NEW2F, offset OLDINT2F>
endif
if ?HOOK13
	INTMOD <13h,offset NEW13, offset OLDINT13>
	INTMOD <40h,offset NEW40, offset OLDINT40>
endif
	INTMOD <67h,offset NEW67, -1>
	INTMOD <06h,offset NEW06, -1>
	INTMOD <19h,offset NEW19, -1>
	db -1

CONST ends

_BSS segment word public 'BSS'
_BSS ends

_STACK segment para STACK  'STACK'
	db 1024 dup(?)		; application stack
stacktop label byte
_STACK ends

DGROUP group _DATA,CONST,_BSS,_STACK

SEG0000 segment word at 0
SEG0000 ends

	.386P

if ?RSEG
RSEG SEGMENT
else
_TEXT SEGMENT
endif

	ASSUME CS:_TEXT16
	ASSUME DS:NOTHING,ES:NOTHING,FS:ERROR,GS:ERROR

;*************************************************************************
; device driver header

device_header:
	dd -1				; last driver in list
	dw 0c000h			; driver flags :
						; 8000 - character device
						; 4000 - supports IOCTL - like EMM386
pStratOfs dw offset strategy	; offset to strategy routine
pIntOfs dw offset driver_entry	; offset to interrupt handler

device_name label byte
	db	'EMMXXXX0'		; device driver name

;--- start of real-mode resident data area

;--- v86 breakpoint table
;--- the order must match the one of bptable in Jemm32.asm !

bptable label byte
NEW06:					; entry invalid opcode exception (int 06)
	@DefineBP BP06
NEW19:
	@DefineBP BP19
NEW67:					; int 67h entry real-mode
	@DefineBP BP67
if ?VDS
NEW4B:					; int 4Bh entry v86-mode (VDS)
	@DefineBP BPVDS
endif
	@DefineBP BPBACK	; BP to return to v86 monitor from a v86 far proc
	@DefineBP BPI1587
if ?HOOK13
	@DefineBP BP1340	; copy out of DMA buffer
endif
	@DefineBP BPXMS 	; handle XMS A20+UMB
	@DefineBP BPSTRAT	; EMMXXXX0 device strategy call
	@DefineBP BPDRV 	; EMMXXXX0 device interrupt call
	@DefineBP BPRESET

if ?HOOK13

bRFlags DB 0

;--- for DMA, hook int 40h (FD access)
;--- and int 13h (HD access)

NEW40 PROC FAR
	mov cs:[bRFlags],2	; tell the monitor that a new DMA op has started
	pushf
	db 09Ah
OLDINT40 dd 0
	jmp int1340common
NEW40 ENDP

	align 4

NEW13 PROC FAR
	mov cs:[bRFlags],2	; tell the monitor that a new DMA op has started
	pushf
	db 09Ah
OLDINT13 dd 0
NEW13 ENDP

int1340common:
	jc iret_with_new_CY
	test cs:[bRFlags],1
	jnz BP1340
iret_with_new_CY:
	push bp
	mov bp,sp
	rcr byte ptr [bp+2+4],1
	rol byte ptr [bp+2+4],1
	pop bp
	iret

endif

;******************************************************************************
; INT15 handler:
;    handle AH=87h case (copy extended memory)
;
;        AH = 87h
;        CX = number of words to copy (max 8000h)
;        ES:SI -> GDT (4 descriptors)
;Return: CF set on error, else cleared
;        AH = status (00 == ok)
;******************************************************************************

	align 4

NEW15 PROC FAR
	CMP AH,87H		; is it the blockmove?
	JZ BPI1587
if ?INTEGRATED
	CMP AH,88H		; ext memory size
	JZ getextmem
endif
	db 0EAh
OLDINT15 dd 0
if ?INTEGRATED
getextmem:
	xor ax,ax			; no memory available
  ife ?HOOK13
	push bp
	mov bp,sp
	and byte ptr [bp+2+4],not 1  ;clear CF
	pop bp
	iret
  else
	jmp iret_with_new_CY
  endif
endif
NEW15 ENDP

;*********************************************************
; XMS hook - required for UMBs and A20 emulation
;*********************************************************

	align 4

XMShandler proc

	jmp short @@XMSHandler	; standard XMS link chain
	nop 					; with 3 required NOPs
	nop
	nop
@@XMSHandler:
if ?INTEGRATED
	jmp BPXMS
else

;-- for A20 disable and enable emulation it is required to hook
;-- the XMS functions as well, even if the A20 ports (92, 60, 64)
;-- are trapped. That's because if certain conditions are true
;-- the XMS host will never access the ports and leave A20 unchanged.

if ?A20XMS
	cmp ah,3
	jb	@@noa20
	cmp ah,6
	jbe BPXMS
@@noa20:
endif

XMSUMB::
	cmp ah,10h			; 10h=alloc, 11h=free, 12=realloc
	jb	@@xms_prev
	cmp ah,12h
	jbe BPXMS
@@xms_prev:
	db 0eah 			; jmp far XMS prev handler
XMSoldhandler dd 0
endif

XMShandler endp

if ?INTEGRATED

NEW2F proc
	pushf
	cmp ah,43h
	jz is43
@@jmp_old2f:
	popf
	db 0EAh
OLDINT2F dd 0
is43:
	cmp al,00h			; is it "Installation Check"?
	je @@get_driver_installed
	cmp al,10h			; is it "Get Driver Address"?
	je @@get_xms_address
	cmp al,09h			; is it "get handle table"?
	je @@get_xms_handle_table
	cmp al,08h
	jne @@jmp_old2f
	mov al,ah		;al==43h if function supported
machine_type label byte    
	mov bx,0002 	; bh=switch time; 0=medium, 1=fast, 2=slow
					; bl=machine type; 1=std AT (KBC), 2=PS/2 (port 92) ?
	popf
	iret
@@get_driver_installed:
	mov al,80h		; yes, we are installed ;)
	popf
	iret
@@get_xms_address:
	mov bx,offset XMShandler
@@shared2f:
	push cs
	pop es
	popf
	iret
@@get_xms_handle_table:
	mov al,ah		;al==43h if function supported
	mov bx,OFFSET xms_handle_table
	jmp @@shared2f

NEW2F endp
endif

if ?RMDBG

;--- print a string in real-mode (for debugging)
;--- preserves registers and flags

VPRINTSTR PROC PUBLIC
	push bp
	mov bp,sp
	XCHG BX,[bp+2]
	PUSHF
	PUSH AX
@@NEXTCHAR:
	MOV AL,CS:[BX]
	INC BX
	CMP AL,0
	JZ @@DONE
	push bx
	mov bx,0007h
	cmp al,LF
	jnz @F
	mov ax,0E0Dh
	int 10h
	mov al,LF
@@:
	mov ah,0Eh
	int 10h
	pop bx
	JMP @@NEXTCHAR
@@DONE:
	POP AX
	POPF
	XCHG BX,[bp+2]
	pop bp
	RET
VPRINTSTR ENDP

;--- display word in AX
;--- preserves registers and flags

VDWORDOUT proc near
	push eax
	shr eax,16
	call VWORDOUT
	pop eax
VDWORDOUT endp
VWORDOUT proc near
	push ax
	mov al,ah
	call VBYTEOUT
	pop ax
VWORDOUT endp
VBYTEOUT proc near
	pushf
	push ax
	mov ah,al
	shr al,4
	call vnibout
	mov al,ah
	call vnibout
	pop ax
	popf
	ret
vnibout:
	and al,0Fh
	cmp al,10
	sbb al,69H
	das
	push bx
	push ax
	mov bx,0007
	mov ah,0Eh
	int 10h
	pop ax
	pop bx
	ret
VBYTEOUT endp

endif

if ?INTEGRATED

	align 2

if ?BUFFERED
?USEDXMSHDL equ 3
else
?USEDXMSHDL equ 2
endif

xms_handle_table XMS_HANDLETABLE <01, size XMS_HANDLE, 2, xms_handle_array>
xms_handle_array XMS_HANDLE ?USEDXMSHDL dup (<XMSF_INPOOL,0,0,0>)        

endif
	align 16

RSEG_END equ $ - device_header

if ?RSEG
RSEG  ends
_TEXT segment
endif

;
; installation part of the virtual Monitor
;

	assume CS:_TEXT16
	assume DS:DGROUP

if ?UNLOAD

CheckIntHooks proc stdcall public uses si di wResSeg:WORD

	mov ax, wResSeg
	shl eax, 16
	push 0
	pop es
	mov si,offset intvecs
@@nextvect:
	lodsb
	cmp al,-1
	jz @@ok
	movzx di,al
	shl di,2
	lodsw
	scasd
	jnz @@nouninst
	add si,2
	jmp @@nextvect
@@ok:
if ?VDS
	assume es:SEG0000
	test byte ptr es:[47Bh],20h
	jz @F
	mov ax,offset NEW4B
	cmp eax,es:[4Bh*4]
	assume es:nothing
	jnz @@nouninst
	@DbgOutS <"TryUnload, int 4Bh is ok",10>,?UNLRMDBG
@@:
endif
	clc
	ret
@@nouninst:
	stc
	ret
CheckIntHooks endp

;--- Jemm can be unloaded. Do it!
;--- in: AX=segment of resident part of installed Jemm
;--- out: C=error, NC=ok. 
;--- may change all GPRs

UnloadJemm proc c public

	mov di,ax

	@DbgOutS <"UnloadJemm enter, CS=">,?UNLRMDBG
	@DbgOutW cs,?UNLRMDBG
	@DbgOutS <" SS=">,?UNLRMDBG
	@DbgOutW ss,?UNLRMDBG
	@DbgOutS <" res. segm=">,?UNLRMDBG
	@DbgOutW di,?UNLRMDBG
	@DbgOutS <10>,?UNLRMDBG

;--- remove EMMXXXX0 from driver chain

	mov ah,52h			;get start of driver chain
	int 21h
	add bx,22h
@@nextdev:
	cmp di, es:[bx+2]
	jz @@found
	les bx, es:[bx]
	cmp bx,-1
	jnz @@nextdev
	stc
	ret
@@found:
	mov ds,di
	mov ecx, ds:[0]    ;remove driver from chain
	mov es:[bx], ecx

	@DbgOutS <"UnloadJemm: driver removed from chain",10>,?UNLRMDBG

;--- reset IVT vectors

	mov es,di
	push 0
	pop ds
	mov si, offset intvecs
@@nextvec:
	db 36h	;SS prefix
	lodsb
	cmp al,-1
	jz @@ok
	movzx bx,al
	shl bx, 2
	mov di,ss:[si+2]
	cmp di,-1
	jz @@skipvec
	mov ecx, es:[di]
	mov ds:[bx],ecx
@@skipvec:
	add si,4
	jmp @@nextvec
@@ok:
	@DbgOutS <"UnloadJemm: IVT vectors restored",10>,?UNLRMDBG

;--- reset XMS hook

ife ?INTEGRATED
	mov bx,offset XMSoldhandler
	mov ecx, es:[bx]
	and ecx, ecx
	jz @@noxms

	push es
	push es
	pop ds
	mov si,offset XMShandler
	push ecx
	pop di
	pop es
	mov cx,5
	sub di,cx
	rep movsb
	pop es
@@noxms:
	@DbgOutS <"UnloadJemm: XMS hook removed",10>,?UNLRMDBG

endif

;--- make sure jemm386's resident memory block is freed
;--- this is to be improved yet

	mov ax,es
	sub ax,10h+1	;size PSP + 10h (to get MCB)
	mov ds,ax
	mov cx,ax
	inc cx
	mov al,ds:[0]
	cmp al,'M'
	jz @@ismcb
	cmp al,'Z'
	jnz @@nopsp
@@ismcb:
	cmp cx, ds:[1]
	jnz @@nopsp
ife ?INTEGRATED
	cmp word ptr ds:[3],10h + RSEG_END/10h
	jnz @@nopsp
else
	cmp word ptr ds:[10h+18h],-1	;check if files 0+1 are closed
	jnz @@nopsp
endif
	cmp word ptr ds:[10h],20CDh
	jnz @@nopsp
	mov ax,cs
	sub ax,10h
	mov ds:[1],ax
@@nopsp:
	@DbgOutS <"UnloadJemm: resident segment prepared to be released",10>,?UNLRMDBG

;--- now call the installed instance of Jemm386 to
;--- do the rest of the clean-up

	push ss
	push bp
	push cs
	push offset rmtarget
	mov bp,sp
	push es
	push offset BPRESET
	call dword ptr [bp-4]

;--- Jemm386 has exited, but we are still in protected mode!
;--- GDTR no longer valid, IDTR reset to 3FF:00000000
;--- for Jemm386, BX contains XMS handle for Jemm386's memory block
;--- for JemmEx, BL contains A20 method index

	mov eax, cr0
	and eax, 7FFFFFFEh	;disable paging and protected-mode
	mov cr0, eax
	mov sp,bp
	retf				;restore CS
rmtarget:
	pop bp
	pop ax
	mov ss,ax
	mov ds,ax
	assume ds:DGROUP
	mov es,ax
	@DbgOutS <"UnloadJemm: back from protected-mode",10>,?UNLRMDBG
	@DbgOutS <"UnloadJemm exit",10>,?UNLRMDBG
	mov ax,bx
	clc
	ret
UnloadJemm endp

endif

; check, if this program runs after all on a 386-Computer (o.ae.)
; (... you never know)

Is386 PROC NEAR
	PUSHF
	mov AX,7000h
	PUSH AX
	POPF				; on a 80386 in real-mode, bits 15..12
	PUSHF				; should be 7, on a 8086 they are F,
	POP AX				; on a 80286 they are 0
	POPF
	and ah,0F0h
	cmp AH,70H
	stc
	JNZ @F
	clc
@@:
	RET
Is386 ENDP

;--- test if CPU is 386, display error if not
;--- returns C and modifies DS in case of error
;--- other registers preserved

TestCPU proc near
	push ax
	call Is386
	jnc @F
	push dx
	push cs
	pop ds
	mov ah,9
	mov dx,offset _TEXT16:dErrCpu
	int 21h
	pop dx
	stc
@@:
	pop ax
	ret
TestCPU endp

dErrCpu  db NAMEMOD,": at least a 80386 cpu is required",13,10,'$'

	assume DS:DGROUP

request_ptr dd 0

;--- the original strategy proc, must be 8086 compatible
;--- will be replaced by a v86 BP once Jemm386 is installed

strategy:
	mov word ptr cs:[request_ptr+0],bx
	mov word ptr cs:[request_ptr+2],es
	retf

;**********************************************
; driver init part
; this code is only necessary on init and
; will not go resident. It must however be
; in the same physical segment as the
; resident part. The proc must be declared far.
;**********************************************

req_hdr struct
req_size db ?	;+0 number of bytes stored
unit_id  db ?	;+1 unit ID code
cmd 	 db ?	;+2 command code
status	 dw ?	;+3 status word
rsvd     db 8 dup(?);+5 reserved
req_hdr ends

init_req struct
	req_hdr <>
units	 db ?	;+13 number of supported units
endaddr  dd ?	;+14 end address of resident part
cmdline  dd ?	;+18 address of command line
init_req ends

driver_entry proc far

	push ds
	push di
	lds di, cs:[request_ptr]	; load address of request header
	mov [di].req_hdr.status,8103h
	cmp [di].req_hdr.cmd,0		; init cmd?
	jne @@noinit
	call TestCPU
	jnc @@cpuok
@@noinit:
	pop di
	pop ds
	ret
@@cpuok:
	mov [di].req_hdr.status,0100h	; set STATUS_OK
	pushad
	mov cx,ss
	mov bx,sp
	mov ax, DGROUP
	mov ss, ax
	mov sp, offset stacktop
	push cx
	push bx
	push es
	push ds
	push di
	les si, [di].init_req.cmdline
	mov ds, ax
	assume	DS:DGROUP
	call EmmInstallcheck
	jnc @F
	xor ax,ax
	jmp @@driver_exit
@@:
	add sp,-128
	mov di,sp
	push ds
	push es
	pop ds
	push ss
	pop es

	cld
if 0
	push si
nextchar:
	lodsb
	cmp al,0
	jz donex
	cmp al,13
	jz donex
	cmp al,10
	jz donex
	mov dl,al
	mov ah,2
	int 21h
	jmp nextchar
donex:
	mov dl,13
	mov ah,2
	int 21h
	mov dl,10
	mov ah,2
	int 21h
	pop si
endif

@@nxtchar1: 			;skip program name
	lodsb
	and al,al
	jz done
	cmp al,13
	jz done
	cmp al,10
	jz done
	cmp al,20h
	ja @@nxtchar1
@@nxtchar2:
	lodsb
	and al,al
	jz done
	cmp al,13
	jz done
	cmp al,10
	jz done
	stosb
	jmp @@nxtchar2
done:
	mov al,0
	stosb
	pop ds
	push sp
	push EXECMODE_SYS
	call mainex
	add sp,128+2+2
;	MOV DX,OFFSET dFailed
	or ax,ax			; error occured?
	mov ax,0
	jnz @@driver_exit
	mov ax, [wLow]
@@driver_exit:
	pop di
	pop ds
	pop es
	mov word ptr [di].init_req.endaddr+0,ax	; if ax == 0, driver won't be installed
	mov word ptr [di].init_req.endaddr+2,cs	; set end address
	pop bx
	pop ss
	mov sp,bx
	popad
	pop di
	pop ds
	ret

driver_entry ENDP

if ?LOAD

;--- check if there is already an EMM installed
;--- DS=DGROUP
;--- out: NC=no Emm found

EmmInstallcheck proc c public
	push es
	pusha
	MOV AX,3567H		; get INT 67h
	INT 21H
	MOV AX,ES			; EMM already installed ?
	OR AX,BX
	JZ @@ok
	MOV DI,10
	MOV SI,OFFSET sig1
	CLD
	MOV CX,8
	REPZ CMPSB
	je @@error			; matched 1st ID string
	mov di, 10			; didn't match, check 2nd ID (NOEMS version)
	mov si, OFFSET sig2
	mov cl, 8
	repz cmpsb
	clc
	jne @@ok			; did match 2nd ID string?
@@error:
	mov dx, CStr('An EMM is already installed',CR,LF,07,'$')
	mov ah, 9
	int 21h
	stc
@@ok:
	popa
	pop es
	ret
EmmInstallcheck endp

endif

;*********************************************
; startpoint when executing as EXE
;*********************************************

start proc

	mov ax, DGROUP
	mov ds,ax
	assume ds:DGROUP
	mov ss,ax
	mov sp, offset stacktop
	call TestCPU
	jc @@exit
	@DbgOutS <"Jemm386 enter",10>,?INITRMDBG

	add sp,-128
	mov di,sp
	push ds
	push es
	pop ds
	mov si,0080h
	lodsb
	movzx cx,al
	push ss
	pop es
	rep movsb
	mov al,0
	stosb
	pop ds

	push sp
	push EXECMODE_EXE
	call mainex		;returns 0 if everything ok
	add sp,128+2+2

if ?LOAD
	and ax,ax		;error occured?
	jnz @@exit
	cmp [wLow],0	;did we move high?
	jz @@exit
	call LinkChain	;link driver in chain for .EXE
	mov ah,51h
	int 21h
	mov es,bx
	assume es:SEG0000
	mov es,es:[002Ch]
	assume es:NOTHING
	mov ah,49h
	int 21h
	mov bx,0
@@nextfile:
	mov ah,3Eh
	int 21h
	inc bx
	cmp bx,5
	jb @@nextfile
	mov dx,[wLow]
	shr dx, 4
	add dx, 10h
	mov ax,3100h
	int 21h
endif

@@exit:
	@DbgOutS <"Jemm386 exit",10>,?INITRMDBG
	mov ah,04ch 		; that was all
	int 21h
start endp

;--- monitor installation
;--- in: SS=DS=DGROUP
;--- out: DX:AX=first page used for EMS/VCPI

InitJemm PROC c public

	push si
	push di
	push bp

if 0; ?A20PORTS 	;this info is unreliable, don't activate!
	mov ax,2403h	;get A20 gate support
	int 15h
	cmp ah,00		;ignore carry flag, it is not reliable
	jnz @F
	mov wBIOSA20,bx
@@:
endif

if ?INTEGRATED
	mov cx, xms_num_handles
	mov [xms_handle_table.xht_numhandles], cx
	mov ax,size XMS_HANDLE
	mul cx
	add ax,offset xms_handle_array + 15
	and al,0F0h
	mov [_brptab.wSizeRes],ax
endif

;--- store interrupt vectors in resident memory

	mov si,offset intvecs
@@nextint:
	mov al,[si].INTMOD.bInt
	cmp al,-1
	jz @@intmoddone
	mov di,[si].INTMOD.wOld
	cmp di,-1
	jz @@nooldsave
	mov ah,35h
	int 21h
	mov cs:[di+0],bx
	mov cs:[di+2],es
@@nooldsave:
	add si,size INTMOD
	jmp @@nextint
@@intmoddone:

;-- set new interrupt routine offset in the driver header, so any further
;-- access to device EMMXXXX0 is handled by the monitor

	mov [pIntOfs],offset BPDRV
	mov [pStratOfs],offset BPSTRAT

;--- prepare running Jemm32
;--- set a GDTR on the stack

	MOV AX, _TEXT32
	mov ES, AX				; ES=_TEXT32
	MOVZX EAX,AX
	SHL EAX,4				; EAX=linear address start of code
ife ?KNOWNGDT
	mov dx,ds
	movzx edx,dx
	shl edx,4
	add edx,offset tmpgdt
	push edx
	push 3*8-1
else
	lea edx, [eax+?GDTOFS]	; assumed GDT position
	push edx
	push 4*8-1
endif

FLAT_CODE_SEL equ 1*8

	push FLAT_CODE_SEL
	push eax
	mov bp,sp
	mov di, offset jemmini	; DI=first parameter
	mov bx, offset _brptab	; BX=second parameter
	CLI
	LGDT FWORD PTR [bp+6]
	push cs
	pop ds					; DS=_TEXT16

	MOV EAX,CR0 			; Set PE-Bit in CR0
	OR AL,1
	MOV CR0,EAX
	call fword ptr [bp] 	; expects ES=_TEXT32, DS=_TEXT16, SS=DGROUP
	add sp,6+6

;--- the remaining commands are executed in v86-mode
;--- the virtual monitor init code has returned with
;--- SS:SP = unchanged
;--- CS, DS, ES, FS, GS = unchanged
;--- EAX = physical address of start of EMS/VCPI memory
;--- interrupts are still disabled

	push ss
	pop ds
	assume DS:DGROUP
	assume ss:DGROUP

	push eax				; FIRSTPAGE value

	@DbgOutS <"V86 mode entered",13,10>,?INITRMDBG

	call GetRes
	mov bx,ax
	push es
if ?INTEGRATED
	mov es,bx
	mov word ptr es:[xms_handle_table.xht_pArray+2],bx
endif
if ?VDS
	push 0
	pop es
	mov ax,cs
	assume es:SEG0000
	cmp ax,word ptr es:[4Bh*4+2]
	jnz @@novds
	mov es:[4Bh*4+2],bx
	assume es:NOTHING
@@novds:
endif
	pop es

	sti

	@DbgOutS <"interrupts enabled, hooking int 15h, 2Fh, ...",13,10>,?INITRMDBG
	mov si,offset intvecs
@@nextint2:
	mov al,[si].INTMOD.bInt
	cmp al,-1
	jz @@intmoddone2
	mov ah,25h
	mov dx,[si].INTMOD.wNew
	push ds
	mov ds,bx
	int 21h
	pop ds
	add si,size INTMOD
	jmp @@nextint2

@@intmoddone2:

	call endinit

ife ?INTEGRATED
	@DbgOutS <"calling InstallXMSHandler",13,10>,?INITRMDBG
	call InstallXMSHandler
endif

	pop eax  ;load FIRSTPAGE value in EAX

	pop bp
	pop di
	pop si
	ret

InitJemm ENDP

	assume ss:nothing
	assume es:nothing
	assume ds:DGROUP

if ?ADDCONT

;--- this will eventually make segment A000-AFFF (and B000-B7FF)
;--- part of conventional DOS memory if option RAM=A000-AFFF is given

AddIfContiguousWithDosMem proc c public
	push bp
	mov bp,sp
	push si
	push es
if 0
	mov ah, 52h
	int 21h
	mov es, es:[bx-2]
@@nextblock:
	mov al, es:[0]
	cmp al,'Z'
	jz @@endfound
	cmp al,'M'
	jnz @@error
	mov ax, es:[3]
	mov cx, es
	add ax, cx
	inc ax
	mov es, ax
	jmp @@nextblock
@@endfound:
	mov ax, es:[3]
	inc ax
	mov cx, es	;save last Z block in cx
	add ax, cx
	mov es, ax
	cmp word ptr es:[1],8
	jnz @@error
	cmp word ptr es:[8],"CS"
	jnz @@error
	inc ax
	mov si, [bp+4]
	cmp ax, si
	jnz @@error

	mov si, [bp+6]

;--- ok, found and contiguous

@@error:
endif
	xor ax, ax
	pop es
	pop si
	pop bp
	ret
AddIfContiguousWithDosMem endp

endif

GetRes proc
	mov ax,jemmini.ResUMB
	and ax,ax
	jz @F
	ret
@@:
	mov ax,cs
	stc
	ret
GetRes endp

;--- end of initialization
;--- 1. init XMS handle table for integrated version
;--- 2. link resident part in driver chain if moved high

endinit proc

if ?INTEGRATED
	mov di, offset xms_handle_array + size XMS_HANDLE * ?USEDXMSHDL
	mov cx, xms_num_handles
	sub cx, ?USEDXMSHDL
	call GetRes
	mov es,ax
@@nexthandle:
	mov ax, XMSF_INPOOL
	stosw
	xor eax, eax
	stosd
	stosd
	loop @@nexthandle
	mov ax, di
	add ax, 16-1
	and al, 0F0h
	mov [wLow], ax
endif

if ?MOVEHIGH
	call GetRes
	jc @F
	mov [wLow],0		;add the EMMXXXX0 driver to the driver chain
	call LinkChain		;if we moved high
@@:
endif
	ret
endinit endp

LinkChain proc
	mov ah,52h
	int 21h
	push ds
	push 0
	pop ds
	mov ax,ds:[67h*4+2]
	mov ds,ax
	add bx,22h
	shl eax,16
	xchg eax,es:[bx]
	mov ds:[0],eax
	pop ds
	ret
LinkChain endp

ife ?INTEGRATED

;--- InstallXMSHandler

InstallXMSHandler proc
ife ?A20XMS 					;if there is no XMS A20 trapping
	cmp jemmini.NumUMBs,0		;XMS hook is needed *only* for UMBs.
	jz @@umbdone				;dont install if no UMBs are supplied
endif
	@DbgOutS <"InstallXMSHandler: getting XMS UMB status",13,10>,?INITRMDBG
	mov dx, -1
	mov ah, 10h
	call [XMSdriverAddress]
	and ax, ax
	jnz @@umbalreadythere
	@DbgOutS <"InstallXMSHandler: hooking into XMS driver chain",13,10>,?INITRMDBG
	les bx,[XMSdriverAddress]
@@nexttest:
	mov al,es:[bx]
	cmp al,0EBh
	jz @@endofchain
	les bx,es:[bx+1]
	cmp al,0EAh
	jz @@nexttest
;--- unexpected pattern found in XMS hook chain
	@DbgOutS <"InstallXMSHandler: unexpected pattern found in XMS hook chain",13,10>,?INITRMDBG
	jmp @@umbdone
@@endofchain:
	@DbgOutS <"InstallXMSHandler: end of chain found",13,10>,?INITRMDBG
	cli
	mov byte ptr es:[bx+0],0EAh
	mov word ptr es:[bx+1],offset XMShandler
	mov cl,jemmini.NumUMBs
	push ds
if ?MOVEHIGH
	push 0
	pop ds
	mov ax,ds:[67h*4+2]
else
	mov ax, cs
endif
	mov es:[bx+3], ax
	add bx,5
	mov ds, ax
	assume DS:_TEXT16
	mov word ptr ds:[XMSoldhandler+0],bx
	mov word ptr ds:[XMSoldhandler+2],es
if ?A20XMS
	cmp cl,0
	jnz @@xmswithumb
	mov byte ptr ds:[XMSUMB], 0EAh	;skip UMB code if no UMBs are supplied
	mov word ptr ds:[XMSUMB+1], bx
	mov word ptr ds:[XMSUMB+3], es
@@xmswithumb:
endif
	pop ds
	assume DS:DGROUP
	sti
	jmp @@umbdone
@@umbalreadythere:
	mov dx, CStr("UMB handler already installed, not installing another one",CR,LF,'$')
	mov ah,9
	int 21h
@@noxms:
@@umbdone:
	ret
InstallXMSHandler endp

endif

;--- init XMS
;--- for the integrated version, init some variables
;--- for the EMM-only version, ensure that an XMS host is found

XMSinit proc c public
	mov ax, 4300h
	int 2fh
	cmp al, 80h
	jne @@not_detected
	mov ax, 4310h
	int 2fh
	mov word ptr [XMSdriverAddress+0], bx
	mov word ptr [XMSdriverAddress+2], es

	mov ax, 4309h		;  XMS get xms handle table
	int 2fh
	cmp al,43h
	jne @@no_table
	mov word ptr jemmini.XMSHandleTable+0, bx
	mov word ptr jemmini.XMSHandleTable+2, es
@@no_table:
	mov ax,1
	ret
@@not_detected:
if ?INTEGRATED
	mov word ptr [XMSdriverAddress+0], offset XMShandler
	mov word ptr [XMSdriverAddress+2], cs
	mov word ptr jemmini.XMSHandleTable+0, offset xms_handle_table
	mov word ptr jemmini.XMSHandleTable+2, cs
endif
	xor ax,ax
	ret
XMSinit endp

if ?INTEGRATED

I15SetHandle proc c public
	mov [xms_handle_array.xh_flags], XMSF_FREE
	mov [xms_handle_array.xh_baseK], 1024+64
	mov [xms_handle_array.xh_sizeK], ecx
	ret
I15SetHandle endp

;--- I15AllocMemory(int dummy, long kbneeded);

I15AllocMemory proc stdcall public dummy:WORD, kbneeded:DWORD

	push ds
	xor ax,ax
	push cs
	pop ds
	mov bx,offset xms_handle_array
	cmp [bx].XMS_HANDLE.xh_flags,XMSF_FREE
	jnz @@fail
	mov ecx, kbneeded
	mov edx, [bx].XMS_HANDLE.xh_sizeK
	sub edx,ecx
	jb @@fail
	mov [bx].XMS_HANDLE.xh_sizeK, ecx
	mov [bx].XMS_HANDLE.xh_locks, 1
	mov [bx].XMS_HANDLE.xh_flags, XMSF_USED
	add ecx, [bx].XMS_HANDLE.xh_baseK
	mov [bx + size XMS_HANDLE].XMS_HANDLE.xh_flags, XMSF_FREE
	mov [bx + size XMS_HANDLE].XMS_HANDLE.xh_sizeK, edx
	mov [bx + size XMS_HANDLE].XMS_HANDLE.xh_baseK, ecx
	mov ax,bx
@@fail:
	pop ds
	ret
I15AllocMemory endp

endif

_TEXT ENDS

	end start
