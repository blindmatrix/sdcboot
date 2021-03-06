
;--- Jemm's initialization part
;--- Public Domain
;--- to be assembled with JWasm or Masm v6.1+

    .486P
    .model FLAT
    option proc:private
    option dotname

    include jemm.inc        ;common declarations
    include jemm32.inc      ;declarations for Jemm32
    include debug.inc

;--- assembly time constants

?SYSPDE     EQU (?SYSBASE shr 20) and 0FFFh     ; offset in pagedir
?SYSPTE     EQU (?SYSLINEAR shr 10) and 0FFFh   ; offset in page table

?PAT        equ 0       ; std=0, 1=use PAT to change WT to WC

if ?FASTMON
?INTTABSIZ  equ 0E0h * 7
else
?INTTABSIZ  equ 100h * 7
endif

;--- publics/externals

    include external.inc

;   assume SS:FLAT,DS:FLAT,ES:FLAT

.text$01 segment
externdef pSmallHeap:dword
externdef dwHeapSize:dword
.text$01 ends

.text$03 segment

RestoreEDI proc
if ?INITDBG
    @DbgOutS <"small heap update ptr=">,1
    @DbgOutD edi,1
    @DbgOutS <10>,1
endif
    mov [pSmallHeap],edi
    pop edi
    ret
RestoreEDI endp

.text$03 ends

@seg .text$03z,<PARA>

    align 4
V86_ENDRES proc public  ;declare a public label so the size is seen in .MAP
V86_ENDRES endp

.text$03z ends

.text$04 segment

;--- here start protected mode initialization code
;--- which is *not* copied to extended memory

;--- IO permission bitmap init values

IOBM label byte

; I/O-control of the DMA-port
; * trap ports 0..7, A, B, C, (D, E, F)
; * trap ports 81,82,83,87, 89,8A,8B
; * trap ports c0..cf
; * trap port d4 d6 d8 (da, dc, de)

if ?DMA or ?A20PORTS
 if ?DMA
  if ?MMASK
;----- FEDCBA9876543210
    DW 1111110011111111b    ; DMA-Controller #1 (00-0F)
  else
;----- FEDCBA9876543210
    DW 0001110011111111b    ; DMA-Controller #1 (00-0F)
  endif
 else
    DW 0                    ; ports 00-0F
 endif
    DW 0,0,0,0,0            ; ports 10-5F
 if ?A20PORTS    
;----- FEDCBA9876543210
  if ?DYNTRAPP60
    DW 0000000000010000b    ; ports 60-6F
  else
    DW 0000000000010001b    ; ports 60-6F
  endif
 else
    DW 0                    ; ports 60-6F
 endif
    DW 0                    ; ports 70-7F
 if ?DMA
;----- FEDCBA9876543210
    DW 0000111010001110b    ; page register (80-8F)
 else
    DW 0                    ; ports 80-8F
 endif
 if ?A20PORTS
;----- FEDCBA9876543210
    DW 0000000000000100b    ; ports 90-9F
 else
    DW 0                    ; ports 90-9F
 endif
    DW 0,0                  ; ports A0-BF
 if ?DMA
;----- FEDCBA9876543210
    DW 1111111111111111b    ; DMA-Controller #2 (C0-CF)
  if ?MMASK
;----- FEDCBA9876543210
    DW 0101010101010000b    ; DMA-Controller #2 (D8-DF)
  else
;----- FEDCBA9876543210
    DW 0000000101010000b    ; DMA-Controller #2 (D8-DF)
  endif
 else
    DW 0,0                  ; ports C0-DF
 endif
endif

IOBM_COPY_LEN equ $ - IOBM

;--- alloc small memory portions from the small heap (if there is one)
;--- only valid during init phase
;--- ecx=requested size in bytes
;--- out: edi=pointer to memory

HeapMalloc proc public
    cmp [dwHeapSize],ecx
    jb @@nomem
    sub [dwHeapSize],ecx
if ?INITDBG
    @DbgOutS <"small heap used, size=">,1
    @DbgOutD ecx,1
    @DbgOutS <", ptr=">,1
    @DbgOutD pSmallHeap,1
    @DbgOutS <10>,1
endif
    xchg edi,[esp]
    push RestoreEDI
    push edi
    mov edi,[pSmallHeap]
@@nomem:
    ret
HeapMalloc endp

;--- check cpu type, return features if CPUID is supported

Is486 proc
    pushfd                      ; save EFlags
    xor edx,edx
    push 240000h                ; set AC+ID bits in eflags
    popfd
    pushfd
    pop eax
    popfd                       ; restore EFlags
    shr eax, 16
    test al,04                  ; AC bit set? then it is a 486+
    mov ah,0
    je @@no_486
    inc ah
    test al,20h                 ; CPUID supported?
    jz @@nocpuid
    xor eax,eax
    inc eax                     ; get register 1
    @cpuid
    mov ah,1
@@nocpuid:
@@no_486:
    mov al,ah
    ret
Is486 endp

if ?FASTBOOT

;--- save IVT vectors
;--- inp: EDI -> free memory

SaveIVT proc
    test [bV86Flags],V86F_FASTBOOT    ;additionally 32*4+32*4+16*4=320
    jz  @@nofastboot
    mov ecx, 32*4+32*4+16*4
    call HeapMalloc
    mov [pSavedVecs],edi 
    xor esi,esi
    mov ecx,32
    rep movsd      ;save vecs 00-1F
    add esi,32*4   ;skip 20-3F
    mov cl,32
    rep movsd      ;save vecs 40-5F
    add esi,8*4    ;skip 60-67
    mov cl,16
    rep movsd      ;save vecs 68-77h
if ?RBTDBG
    mov esi,[pSavedVecs]
    mov ecx,20h
    xor ebx,ebx
@@: 
    lodsd
    @DbgOutB bl,1
    @DbgOutS <": ">,1
    @DbgOutD eax, 1
    @DbgOutS <"        ">,1
    inc ebx
    loop @B
    @DbgOutS <10>,1
endif
@@nofastboot:
    ret
SaveIVT endp
endif

if ?SHAREDIDT
externdef V86IDT:near
endif

;--- set int EAX to value of ECX

SetIDTEntry proc
if ?SHAREDIDT
    mov word ptr [offset V86IDT+eax*8+0], cx
    shr ecx,16
    mov word ptr [offset V86IDT+eax*8+6], cx
else
    push ebx
    mov ebx,[dwV86IDT]
    mov word ptr [ebx+eax*8+0], cx
    shr ecx,16
    mov word ptr [ebx+eax*8+6], cx
    pop ebx
endif
    ret
SetIDTEntry endp

;--- Monitor initialization

;--- input expected:
;--- CPU in protected-mode, interrupts disabled, paging disabled
;--- GDTR = GDT
;--- CS = FLAT selector (FLAT_CODE_SEL)
;--- SS = DGROUP
;--- DS = RSEG
;--- ES = _TEXT32 (=conv. memory segment where this code has been loaded)
;--- BX = offset BRPTAB
;--- DI = offset JEMMINIT, contains:
;---  MonitorStart      : start of EMB for the monitor
;---  MonitorEnd        : end of EMB for monitor
;---  MaxMem16k         : MAX=xxxx cmdline option given, or 1E00 (120 MB)
;---  TotalMemory       : total size of physical memory
;---  XMS_Handle_Table  : returned by int 2f, ax=4309h
;---  MaxEMSPages       : maximum EMS 16k pages, default 32 MB
;---  XMS_Control_Handle: XMS handle for monitor extended memory block
;---  DMA_Buffer_Size   : size of DMA buffer in kB
;---  Frame             : FRAME=xxxx parameter
;---  NoEMS, NoFrame, NoPool, AltBoot, NoVME, NoVDS, NoPGE, NoA20, NoVCPI

;--- memory layout installed by the initialization code:
;--- shared memory (110000 - 11xxxx):
;---  0-3.0 kB    wasted space because of rounding to page border
;---    0.125 kB  monitor help stack for VCPI
;---  ~14.0 kB    resident monitor data+code (V86_ENDRES - ?BASE)
;---    0.5 kB    GDT  [GDT_PTR] (size 200h)
;---    2.0 kB    IDT  [IDT_PTR]
;---   ~1.7 kB    interrupt table (size E0h*7)
;---  0-3.0 kB    wasted space because of rounding to page border
;---              (if > 2 kB it is filled with STATUSTABLE)

;--- linear addresses in sys space (F80000000 - F803FFFFF):

;---    4   kB    reserved
;---   12   kB    page directory, page table 0, sys page table
;---    4   kB    ring 0 stack
;---   ~8.2 kB    TSS (size ?TSSLEN)
;---              DMABuffStart (0-?DMABUFFMAX kB)
;---              para align
;---    1   kB    EMSHandleTable (size 4*255)
;---    1   kB    EMSStateTable (size 8*128)
;---    2   kB    EMSNameTable (size 8*255)
;---              EMSPageAllocationStart (EMS pages * 4 bytes) 
;---              EMSPageAllocationOfs (EMS pages * 1 bytes) 
;---              64 byte align
;---              PoolAllocationTable (128*64 + x)
;---  0-3.0 kB    page align
;---              start of "free" memory in this very first XMS block
;---              (used for UMBs, if NODYN used for EMS/VCPI as well)

InitMonitor PROC public

;--- local variables:

jemmini     equ <[ebp-4]>
rsofsinit   equ <[ebp-8]>
tmpPageMask equ <[ebp-11]>
tmpIs486    equ <[ebp-12]>
tmpFeatures equ <[ebp-16]>
dwSizeV86   equ <[ebp-20]>

    CLD
    pop esi                 ; get return EIP
    pop edx                 ; get return CS (real-mode)
    mov eax,esp
    mov ecx,ss              ; SS contains DGROUP
    movzx ecx,cx
    mov EBP,ECX
    shl EBP, 4
    movzx ESP, SP
    add EBP, ESP
    mov SP,FLAT_DATA_SEL
    mov SS,ESP
    mov ESP,EBP

;--- now SS:ESP -> real-mode SS:SP

    push gs         ; +32 real-mode GS
    push fs         ; +28 real-mode FS
    push ds         ; +24 real-mode DS
    push es         ; +20 real-mode ES
    PUSH ecx        ; +16 SS (=DGROUP)
    PUSH eax        ; +12 ESP
    PUSH 00023002H  ;  +8 EFL (VM=1, IOPL=3, NT=0, IF=0)
    PUSH edx        ;  +4 CS
    PUSH esi        ;  +0 EIP
    mov ebp,esp     ; ebp -> IRETDV86

    XOR EAX,EAX
    LLDT AX                 ; initialise LDT (it is not used)
    mov FS,EAX
    mov GS,EAX
    MOV AL,FLAT_DATA_SEL    ; Addressing everything
    MOV DS,EAX
    MOV ES,EAX

;--- segment registers now:
;--- CS,SS,DS,ES: FLAT  
;--- FS,GS: NULL  
;--- no access to global variables possible until paging is enabled
;--- and memory block has been moved to extended memory!

if ?INITDBG
    @DbgOutS <"Welcome in PM",10>,1
    @WaitKey 1,0
endif

    shl ecx, 4
    movzx edi, di
    add edi, ecx            ;get linear address of jemmini
    push edi                ;== jemmini [ebp-4]


    movzx ebx, bx
    add ebx, ecx
    push ebx                ;== rsofsinit [ebp-8]

if 1
    pushfd                      ; clear the NT flag to avoid a "reboot"
    and byte ptr [esp+1],not 40h; at next IRET in protected-mode
    popfd
endif

    mov esi, jemmini

    call Is486
    push eax                 ;== tmpPageMask [ebp-12]
    push edx                 ;== tmpFeatures [ebp-16]
    and al,al
    jz @F
    cmp [esi].JEMMINIT.NoInvlPg,-1
    jnz @F
    mov [esi].JEMMINIT.NoInvlPg,0
@@:

    MOV EDI,[esi].JEMMINIT.MonitorStart ; Start of Monitor-Code
if ?INITDBG
    push edi
    mov ecx,[esi].JEMMINIT.MonitorEnd
    sub ecx,edi
    shr ecx,2
    mov eax,0DEADBABEh
    rep stosd
    pop edi
endif

ife ?INTEGRATED
    ADD EDI,1000h-1     ; Round to the next page border
    AND DI,NOT 1000h-1  ; may waste up to 3 kB (not for JemmEx)
endif

;-- calc size of the items which must be in page table 0:
;-- GDT, (IDT), (stack), code+data

;-- ?INTTABSIZ is size of INT_TABLE

    mov eax, offset V86_ENDRES
if ?SHAREDIDT
    sub eax, ?BASE - ( ?INTTABSIZ)  ;size of resident code+data
else
    sub eax, ?BASE - ( ?INTTABSIZ + 800h)
endif
    add eax, 1000h-1
    and ax, not 1000h-1 ;round to next page (may waste another 3 kB!)

    mov ebx, edi        ;save physical address in EBX
    add edi, eax

    push eax            ;== dwSizeV86 [ebp-20], size of code+GDT+IDT

if 0
    mov eax, cr3
    and eax, 0FFFh      ;don't touch low 12 bits of CR3
    or eax, edi
    MOV CR3, eax        ;set CR3 (paging is still disabled)
else
    mov cr3, edi
endif

;-- clear pagedir, page table 0 + system page table

    push edi
    mov ecx, 3000h/4
    xor eax, eax
    rep stosd
    pop edi

;-- init page dir (2 PDEs)

    mov ah,10h  ;=mov eax,1000h

    lea edx, [edi+eax]
    MOV [EDI+000h],EDX
    OR DWORD PTR [EDI+000h],1+2+4
    add edx, eax
    mov [EDI+?SYSPDE], EDX
    OR DWORD PTR [EDI+?SYSPDE],1+2+4

    add edi, eax     ;edi -> mapped page table 0

    push edx         ;save mapped system page table

;-- init page table 0 address space 0-110000h

    mov edx, 1+2+4  ;set page flags u/ser, w/riteable, p/resent
if ?PGE
    test byte ptr tmpFeatures+1,20h  ;PGE supported?
    jz @F
    or dh,1         ;set G bit (page global)
@@:
    mov tmpPageMask,dh
endif
    mov cx,110h     ;hiword ecx is cleared
    mov eax,edx
@@:
    stosd
    ADD EAX,1000h
    loop @B

if 0
;-- give the video region A000-BFFF some special attributes
    push edi
    sub edi, (110h*4 - 0A0h*4)
    mov cl,20h
@@:
    or dword ptr [edi],8h  ;set "WT"
    add edi,4
    loop @B
    pop edi
endif

;-- init page table 0 address space 110000h-?

    mov ecx, dwSizeV86  ;size of space above 110000h (page aligned)
    shr ecx, 12         ;is just a handful of pages
    mov eax, ebx        ;get physical address of this space
    or al, 1+2          ;set PRESENT + R/W
if ?PGE
;--- set first page (which is shared) global
    or ah, tmpPageMask
endif

@@:
    stosd
    ADD EAX,1000h
if 0
    and al, not 4   ;all pages except the first are "system"
endif
if ?PGE
    and ah, 0F0h
endif
    loop @B

;-- for VCPI intruders, set remaining PTEs in page tab 0
;-- if they still aren't satisfied, they may be just stupid.

    push eax
if 1    ;SBEINIT.COM *is* stupid, needs linear=physical mapping
    movzx eax, di
    and ah, 0Fh
    shl eax, 10     ;transform offset in page table -> linear address
    or al,1+2+4
endif
    mov cx, 400h    ;hiword ecx is clear
@@:
    stosd
    ADD EAX,1000h
    test di,0FFFh
    loopnz @B
    pop eax

;-- init system page table with the rest.
;-- in a first step just 3 PTEs are needed (to map page tables)

    pop edi         ;get saved mapped system page table
    add edi, ?SYSPTE
    mov ecx,3+1     ;+ 4k stack
@@:
    stosd
    ADD EAX,1000h
    loop @B

    push eax         ;save physical address free memory

;--- page dir, page tab 000 and sys page tab are now initialized,
;--- paging can be enabled.

    MOV EAX,CR0
    OR EAX,80000000H       ; set PE bit
    MOV CR0,EAX
if ?INITDBG
    @DbgOutS <"Paging has been enabled",10>,1
    @WaitKey 1,0
endif

;--- paging enabled, now move monitor code+data in extended memory

    mov edi, ?BASE
    movzx esi, word ptr [ebp].IRETDV86.vES    ;real-mode ES contained _TEXT32
    shl esi, 4

if 0
;--- resolve base fixups
;--- this is usually not needed, since the binary has been linked
;--- for base address 110000h

    pushad
    add esi, V86_TOTAL  ;the relocs are just behind the 32bit block
    xor edx, edx
    xchg dx,[esi]        ;get size of header (hack!)
nextpage:
    mov ebx, [esi+0]
    mov ecx, [esi+4]
    and ecx, ecx
    jz reloc_done
if ?INITDBG
    @DbgOutS <"rlcs at ">
    @DbgOutD esi,1
    @DbgOutS <" for page ">,1
    @DbgOutD ebx,1
    @DbgOutS <" size=">,1
    @DbgOutD ecx,1
    @DbgOutS <" edx=">,1
    @DbgOutD edx,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif
    add ecx, esi
    add esi, 8
    sub ebx, edx        ;subtract size of header from RVA
    add ebx, [esp]      ;add conv. base to address
    xor eax, eax
nextreloc:
    lodsw
    test ah,0F0h
    jz @F
    and ah,0Fh
    add [eax+ebx], edi
@@:
    cmp esi, ecx
    jb nextreloc
    jmp nextpage
reloc_done:
    popad
if ?INITDBG
    @DbgOutS <"base relocs done",10>,1
    @WaitKey 1,0
endif
endif

;-- copy all to extended memory (linear address 110000h)

    MOV ECX, offset V86_ENDRES
    sub ecx, edi
    shr ecx, 2
    rep movsd

if ?INITDBG
    @DbgOutS <"monitor code+data moved to extended memory",10>,1
    @WaitKey 1,0
endif

;--- after code + data has been moved to extended memory
;--- access to global variables is possible

;--- load final values for GDTR + IDTR

    LGDT FWORD PTR [GDT_PTR]
if ?INITDBG
    @DbgOutS <"GDTR set",10>,1
    @WaitKey 1,0
endif

;--- switch to the stack in extended memory

if 0
    mov ebp, ?TOS - size IRETDV86
    lea esp, [ebp-20]   ;take care of the local variables

if ?INITDBG
    @DbgOutS <"ESP reset",10>,1
    @WaitKey 1,0
endif

endif

;--- edi para aligned again (increased by 700h/690h)
;--- EDI -> free linear memory
;--- EBX -> free space for PTEs in system page table

    MOV EAX,CR3
    MOV [V86CR3],eax

    mov eax, tmpFeatures
    mov [dwFeatures], eax
    mov eax, tmpIs486
    mov [bIs486], al

if ?PGE
    mov [bPageMask],ah
endif

    MOVZX ECX,word ptr [ebp].IRETDV86.vDS
    MOV [dwRSeg], ecx
    SHL ECX,4
    mov [dwRes],ecx

    mov esi, jemmini

    mov eax, [esi].JEMMINIT.TotalMemory
    mov [dwTotalMemory],eax
    mov eax, [esi].JEMMINIT.MaxMem16k
    shl eax, 2
    mov [dwMaxMem4K],eax
    mov al, [esi].JEMMINIT.NoPool
    mov [bNoPool],al

    mov al, [esi].JEMMINIT.NoInvlPg
    mov [bNoInvlPg],al
    mov al, [esi].JEMMINIT.V86Flags
    mov [bV86Flags],al

    push ecx

    call XMS_Init

if ?DBGOUT
    call Debug_Init
endif

    call EMS_Init1

    pop ecx

    mov esi, rsofsinit

    movzx eax,[esi].RSOFS.wBpTab
    mov [bBpTab],al
    add [bBpBack],al
    add eax,ecx
    mov [bpstart],eax

if ?HOOK13
    movzx eax,[esi].RSOFS.wRFlags
    add eax,ecx
    mov [dwRFlags],eax
endif
if ?INITDBG
    @DbgOutS <"variables copied",10>,1
    @WaitKey 1,0
endif

;-- create INT_TABLE + set IDT
;-- some VCPI intruders won't work if IDT is not in page table 0 !!!

    mov ebx, 0EE00h shl 16 + FLAT_CODE_SEL
    mov ecx, 100h
if ?SHAREDIDT
    mov esi, offset V86IDT
else
    mov esi, edi
    mov [dwV86IDT], esi
    add edi, 100h*8
endif
if ?FASTMON
    mov eax, offset int00
@@:
;   @DbgOutS <".">,?INITDBG
    mov edx, eax
    shr edx, 16
    mov [esi+0],ax
    mov [esi+2],ebx
    mov [esi+6],dx
    add eax, 4
    add esi, 8
    dec ecx
    cmp cl,100h - ?FASTENTRIES
    jnz @B
;   @DbgOutS <10>,?INITDBG
    mov edx, 0E9006Ah
    mov dh,?FASTENTRIES
else
    mov edx, 0E9006Ah       ;push byte 00h, jmp xxxx
endif
@@nextidtentry:
;   @DbgOutS <".">,?INITDBG
    mov eax, edi
    mov [esi+0],ax
    mov [esi+2],ebx
    shr eax, 16
    mov [esi+6],ax
    mov [edi+0],edx
    mov eax, offset V86_Monitor
    add edi,7       ;7 bytes for each entry in INT_TABLE!
    sub eax, edi
    mov [edi-4],eax
    inc dh          ;next INT #
    add esi,8
    loop @@nextidtentry
;   @DbgOutS <10>,?INITDBG

    LIDT FWORD PTR [IDT_PTR]
if ?INITDBG
    @DbgOutS <"IDTR, IDT + int table initialized, IDT=">,1
    @DbgOutD <dword ptr [IDT_PTR+2]>,1
    @DbgOutS <" EDI=">,1
    @DbgOutD edi,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

;--- use any rest as "small heap"
;--- it can be used by EMS - if it is large enough

    lea ecx,[edi+1000h-1]
    and cx,0F000h
    sub ecx, edi
    mov [pSmallHeap], edi
    mov [dwHeapSize], ecx

;--- the memory in page tab 0 is initialized

;--- until now are consumed:
;--- 3 pages for pagedir+pagetab
;--- 4-5 pages for monitor (hlp stack,) GDT, IDT, data, code

    pop ebx ; get free phys mem ptr

if ?INITDBG
    @DbgOutS <"page table 0 initialised, EDI=">,1
    @DbgOutD edi,1
    @DbgOutS <" EBX=">,1
    @DbgOutD ebx,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

if ?DMA

;--- set bits in DMABuffFree bit array

    mov esi, jemmini
    movzx eax, [esi].JEMMINIT.DMABufferSize ;buffer size in kB
    shl eax, 10
    mov ecx, eax
    shr ecx, 10
    inc ecx     ;add start and end bit
    inc ecx
    xor edx, edx
@@:
    bts [DMABuffFree], edx
    inc edx
    loop @B

;-- ensure DMA buffer doesn't cross a 64kb border

    mov ecx, ebx
    and cx,0F000h
    lea edx, [ecx+eax-1]    ;edx -> last byte of buffer
    
    cmp edx, 1000000h       ;DMA must be below 16M border
    jc @F
    xor eax, eax
@@:
    mov [DMABuffSize], eax
    and eax, eax
    jz @@buffernull

    mov eax, edx
    shr eax, 16
    mov edi, ecx
    shr edi, 16
    sub eax, edi    ;does buffer cross a 64 kB boundary?
    jz @@buffergood

;-- align it to the next 64 kB boundary

    inc edi
    shl edi,16
    mov eax,edi
    sub eax,ecx
    add ecx,eax     ;in eax now amount of free mem below DMA buffer
@@buffergood:

;--- map DMA buffer in linear address space

    pushad
    mov eax, ecx
    mov ecx, [DMABuffSize]  ; will be page aligned
    shr ecx, 12
    call MapPhysPagesEx
    mov [DMABuffStart], eax
    add edx,4
    mov [PageMapHeap], edx

if ?INITDBG
    mov edi, eax
    mov ecx, [DMABuffSize]
    shr ecx, 2
    mov eax, "BAMD"
    rep stosd
endif

    popad

@@buffernull:
    MOV [DMABuffStartPhys], ecx

if ?INITDBG
    @DbgOutS <"DMA buffer linear=">,1
    @DbgOutD [DMABuffStart],1
    @DbgOutS <" physical=">,1
    @DbgOutD [DMABuffStartPhys],1
    @DbgOutS <" size=">,1
    @DbgOutD [DMABuffSize],1
    @DbgOutS <" phys rest=">,1
    @DbgOutD eax,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

endif

;--- dma buffer initialized
;--- fill ring 0 stack with "STAK"

    push eax     ;rest of physical mem below DMA buffer

    mov edi, ?SYSLINEAR + 3000h ; skip page dir + 2 page tables
    mov eax,"KATS"
    mov ecx, 1000h/4
    rep stosd

if ?INITDBG
    @DbgOutS <"stack initialized">,1
    @DbgOutS <10>,1
endif

;-- now create a heap
;-- set rest of PTEs in system page table

;-- what amount of space is needed ?
;--   tss:   104 + 32 + 8192 + 8  ->   8336
;--  pool:  maxmem16k * 64 / 96   ->   5120 (for 120 MB/30720 4k pages)
;--  pool:  xms handles * 64      ->   2048 (for 32 XMS handles)
;--   ems:  handles (255*4)       ->   1020 (for 255 handles)
;--   ems:  state save (64*16)    ->   1024 (for 64 states)
;--   ems:  name array (255*8)    ->   2040 (for 255 names)
;--   ems:  page array (2048*5)   ->  10240 (for 2048 pages)
;----------------------------------------------------------------
;                                     29828

    push ebx
    mov ecx, ?TSSLEN    ;8336

;--- calc number of pages still needed in sys page table
;--- 1. the pages for pool management:
;--- maxmem16k * 64 / 96

    mov eax, [esi].JEMMINIT.MaxMem16k
    shl eax, 6      ;*64
    xor edx, edx
    mov ebx, 96
    div ebx
    add eax, 64*2
    add ecx, eax

    cmp [bNoPool],0
    jnz @@isnopool
    movzx eax,[XMS_Handle_Table.xht_numhandles]
    shl eax, 6
    add ecx, eax
@@isnopool:    
if ?INITDBG
    @DbgOutS <"for TSS+pool=">,1
    @DbgOutD ecx,1
endif

;--- 2. the pages required for ems handling

;--- a. var space (5 * maxEMSpages)

    movzx eax, [esi].JEMMINIT.MaxEMSPages
    lea eax, [eax+eax*4]    ;each EMS page needs 5 bytes
    
;--- b. fix space (EMS handle table, state table, name table)

    add eax, EMS_MAX_HANDLES*size EMSHD + EMS_MAXSTATE*size EMSSTAT + EMS_MAX_HANDLES*8

if ?INITDBG
    @DbgOutS <", for EMS=">,1
    @DbgOutD eax,1
endif

    add ecx, eax

if ?INITDBG
    @DbgOutS <", total=">,1
    @DbgOutD ecx,1
endif

;--- 3. round up to 4k

    add ecx, 4096-1

;--- 4. convert to 4k page

    shr ecx, 12

    pop ebx
    pop eax

if ?INITDBG
    @DbgOutS <", remaining bytes=">,1
    @DbgOutD eax,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

    @SYSPTE2LINEAR edi, [PageMapHeap]

;--- here:
;--- eax = amount of space below DMA buffer (in bytes)
;--- ebx = physical address of space below DMA buffer
;--- edi = linear address free memory
;--- ecx = amount of memory needed (in pages)

    mov edx,[PageMapHeap]
    shr eax, 12
    jz @@nospacebelow   ;jump if nothing left below DMA buffer
    push ecx
    push eax
    mov ecx, eax
    mov eax, ebx
    call MapPhysPages
    pop eax
    pop ecx
@@nospacebelow:
    sub ecx, eax        ;space above DMA buffer needed?
    jbe @@nospaceabove
    mov eax, [DMABuffStartPhys]
    add eax, [DMABuffSize]
if ?INITDBG
    @DbgOutS <"heap region above DMA buffer ">,1
    @DbgOutD eax,1
    @DbgOutS <", size ">,1
    @DbgOutD ecx,1
    @DbgOutS <", pPTE=">,1
    @DbgOutD edx,1
    @DbgOutS <10>,1
endif
    call MapPhysPages
@@nospaceabove:
    add edx,4           ;leave 1 page in address space reserved
    mov [PageMapHeap],edx

if ?INITDBG
    @DbgOutS <"heap created at ">
    @DbgOutD edi,1
    @DbgOutS <"-">,1
    lea ebx, [edx-4]
    @SYSPTE2LINEAR ebx, ebx
    dec ebx
    @DbgOutD ebx,1
    @DbgOutS <", free PTEs starting at ">,1
    @DbgOutD edx,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

;--- now create the TSS (will begin on a page boundary, since DMA buffer
;--- size is rounded to 4 kB).

if ?DYNTRAPP60
    mov [dwTSS], edi
endif
    mov ebx, offset V86GDT
    mov eax, edi
    MOV WORD PTR [EBX+V86_TSS_SEL+2],AX
    SHR EAX,16
    MOV BYTE PTR [EBX+V86_TSS_SEL+4],AL
    MOV BYTE PTR [EBX+V86_TSS_SEL+7],AH

;--- init TSS, the software interrupt redirection bitmap (256 bits) + io-bitmap
;--- it is known by Pentium+ cpus only, but doesn't hurt for previous cpus

    mov edx, edi    
    mov ecx, size TSSSEG/4 + 32/4 + (65536/8)/4
    xor eax, eax
    rep stosd   ;clear TSS, io-bitmap, ...
    dec eax
    stosb           ;the IO bitmap must be terminated by a FF byte

    mov dword ptr [edx].TSSSEG.tsEsp0, ?TOS
    mov dword ptr [edx].TSSSEG.tsSS0, FLAT_DATA_SEL
if 1
    mov eax, [V86CR3]       ; save value for CR3 in TSS (not needed)
    mov [edx].TSSSEG.tsCR3, eax
endif
    mov [edx].TSSSEG.tsOfs,size TSSSEG+32 ;let 32 bytes space below IO Bitmap

;-- init the io permission bitmap

    movzx esi, word ptr [ebp].IRETDV86.vES
    shl esi, 4
;   add esi, offset IOBM - offset _start
    add esi, offset IOBM - ?BASE
    lea edi, [edx+size TSSSEG+32]
    mov ecx,IOBM_COPY_LEN
    rep movsb

if ?INITDBG
    @DbgOutS <"TSS done, esp0=">,1
    @DbgOutD [edx].TSSSEG.tsEsp0,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

;-- finally load TR

    mov ax, V86_TSS_SEL
    ltr ax

;--- here CR3, GDTR, IDTR, TR and LDTR all have their final values

    lea edi, [edx+ ?TSSLEN]

;--- modify IDT and vector bitmap
;--- int 67h must be handled by the monitor in any case

    add edx, size TSSSEG

    xor eax, eax
    mov al, 67h
    mov ecx, offset Int67_Entry
    bts [edx], eax
    call SetIDTEntry

    mov al, 15h
    mov ecx, offset Int15_Entry
    bts [edx], eax
    call SetIDTEntry

if ?BPOPC ne 0F4h
    mov al,6
    mov ecx, offset Int06_Entry
;   bts [edx], eax          ;not required since it is an exception
    call SetIDTEntry
endif

if ?EXC10
    mov al,10h
    mov ecx, offset Int10_Entry
    call SetIDTEntry
endif

    mov esi,jemmini

if ?VME
    mov al,[esi].JEMMINIT.NoVME
    xor al,1
    call SetVME
endif
if ?PAT
    test [dwFeatures],10000h
    jz @@nopat
    mov ecx,277h
    @rdmsr
    mov ah,01   ;change 00-07-04-06 to 00-07-01-06
    @wrmsr
@@nopat:
endif

if ?A20PORTS
 if 0
    xor eax, eax
    test byte ptr wBiosA20,1 ;keyboard controller can switch A20?
    jnz @@kbdA20
    mov al, 60h
    btr [edx], eax
    mov al, 64h
    btr [edx], eax
@@kbdA20:
    test byte ptr wBiosA20,2 ;port 92h can switch A20?
    jnz @@ps2A20
    mov al, 92h
    btr [edx], eax
@@ps2A20:
 endif
endif

if ?INITDBG
    @DbgOutS <"Jemm initialised, edi=">,1
    @DbgOutD edi,1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

if ?FASTBOOT
    call SaveIVT
endif

    mov esi, jemmini

;--- Pool init

    call Pool_Init1

;--- EMS/VCPI init

    call EMS_Init2

;--- convert EDI back into a physical address
;--- use the page directory for the conversion

    mov eax, edi
    sub eax, ?SYSLINEAR
    shr eax, 12

    and edi, 0FFFh

if 0
    setnz cl
    movzx ecx,cl

    @GETPTEPTR esi, ?PAGETABSYS+eax*4+?SYSPTE

;--- clear the PTEs which are not used in the heap

    lea esi,[esi+ecx*4]
    xor ecx, ecx
@@nextptecl:
    cmp ecx,[esi]
    jz @@cldone
    mov [esi],ecx
    add esi,4
    jmp @@nextptecl
@@cldone:
endif

    @GETPTE eax, ?PAGETABSYS+eax*4+?SYSPTE
    and ah, 0F0h
    mov al, 0

if ?INITDBG
    @DbgOutS <"End of monitor: ">,1
    @DbgOutD edi,1
    @DbgOutS <", last physical page used: ">,1
    @DbgOutD eax,1
    @DbgOutS <10>,1
endif

;--- now check if heap's last physical page is < DMA buffer
;--- if yes, all pages below must be skipped and are wasted
;--- since the EMS/VCPI memory managment needs a contiguous block
;--- of physical memory as input.

    mov ecx, [DMABuffStartPhys]
    cmp eax, ecx
    jnc @@abovedma
if ?INITDBG
    @DbgOutS <"must waste space, phys end of monitor=">,1
    @DbgOutD eax,1
    @DbgOutS <" is below DMA buff=">,1
    @DbgOutD ecx,1
    @DbgOutS <10>,1
endif
    add ecx, [DMABuffSize]      ;get physical end of the DMA buff
    mov eax, ecx
    xor edi, edi
@@abovedma:
    add edi, eax
    mov esi, jemmini
    mov eax, [esi].JEMMINIT.MonitorEnd

    cmp eax, EDI
    jnc @@nomemproblem      ;run out of memory?

; ran out of memory, shouldn't happen, avoid disaster by setting
; max VCPI/EMS memory to 0

if ?INITDBG
    @DbgOutS <"out of memory condition on init!, MonitorEnd=">,1
    @DbgOutD [esi].JEMMINIT.MonitorEnd,1
    @DbgOutS <" EDI=">,1
    @DbgOutD edi,1
    @DbgOutS <10>,1
endif

    mov [EMSPagesMax], 0
    mov [dwMaxMem4K], 0
    jmp @@initdone

@@nomemproblem:
if ?INITDBG
    @DbgOutS <"end of monitor data, physical=">,1
    @DbgOutD edi,1
    @DbgOutS <", end of XMS memory block=">,1
    @DbgOutD eax,1
    @DbgOutS <10>,1
endif

;--- force 4K alignment for EMS/VCPI fixed pages and UMB's

    ADD EDI,4095
    AND DI,NOT 4095
    
    sub eax, edi
    jnc @F
    xor eax, eax
@@:

;--- eax=rest of monitor memory block
;--- edi=physical address
;--- esi=JEMMINIT

;--- now init the UMBs. these should not affect VCPI/EMS memory 

    cmp [esi].JEMMINIT.NoRAM,0
    jnz @@noumbmapping

    @DbgOutS <"UMB init start",10>,?INITDBG

    push ebp
    mov ebp, eax

    movzx ebx,word ptr [esi].JEMMINIT.PageMap+0
    movzx edx,word ptr [esi].JEMMINIT.PageMap+2
    shl edx,4
    add ebx,edx

;--- map in the UMB pages

    mov ecx,0A0h
@@nextitem:
    cmp ebp,1000h       ;are 4k still available?
    jc @@umbmemout
    mov al,[ebx+ecx]
    call IsUMBMemory
    jc @@skippage
if ?SPLIT
    and ah,ah
    jz @@isstdumb
    call CopyROM
    jmp @@pageshadowed
@@isstdumb:
endif
    @GETPTEPTR EAX, ?PAGETAB0+ecx*4
    mov edx,[eax]
    and edx,0FFFh       ;don't modify the PTE bits
    or edx,edi
    mov [eax],edx
@@pageshadowed:
;    @DbgOutB cl,?INITDBG
;    @DbgOutC ' ',?INITDBG
    add edi,1000h
    sub ebp,1000h
@@skippage:
    inc cl
    jnz @@nextitem
@@umbmemout:
    mov eax,ebp
    pop ebp

    @DbgOutS <"UMBs mapped",10>,?INITDBG

@@noumbmapping:

;   cmp [esi].JEMMINIT.AltBoot,0
;   jnz @@noshadow

;-- shadow ROM page 0FFh to catch jumps to FFFF:0
;-- to fill the the new page with the content of the ROM, map it
;-- at linear scratch pos and copy the content.

    cmp eax,1000h   ;is enough free space available?
    jc @@noshadow
    mov ecx, 0FFh
    call CopyROM
    mov WORD PTR ds:[0FFFF0h],19CDh     ; set "INT 19h" at FFFF:0000
    @GETPTEPTR EDX, ?PAGETAB0+ecx*4
    and byte ptr [edx],not 2        ; make this page R/O
    add edi,1000h
    sub eax,1000h
@@noshadow:

;--- flush TLB to activate the UMBs and shadow ROMs

    mov ecx,cr3
    mov cr3,ecx

if ?PGE
    test byte ptr tmpFeatures+1,20h  ;PGE supported?
    jz @F
    cmp [esi].JEMMINIT.NoPGE,0
    jnz @F
    @mov_ecx_cr4
    or cl,80h
    @mov_cr4_ecx
@@:
endif

    MOV [tmpFeatures],EDI   ; save phys addr of first EMS-page

;--- EDI -> start free mem
;--- EAX -> free mem size

    shr eax,12                  ; convert bytes to 4k pages
    call Pool_Init2

if ?INTEGRATED

;--- for the integrated version the rest of the memory can be released now

ife ?BUFFERED   ;avoid this if debug output is buffered


    mov ebx,[XMS_Handle_Table.xht_pArray]
    mov ecx, edi
    shr ecx, 10
    mov eax, [ebx+size XMS_HANDLE].XMS_HANDLE.xh_baseK
    sub eax, ecx
    jbe @@nothingtorelease
    sub [ebx].XMS_HANDLE.xh_sizeK, eax
    add [ebx+size XMS_HANDLE].XMS_HANDLE.xh_sizeK, eax
    mov [ebx+size XMS_HANDLE].XMS_HANDLE.xh_baseK, ecx
@@nothingtorelease:
endif

endif

@@initdone:

if ?INITDBG
    @DbgOutS <"EMS/VCPI memory handling initialised, MaxMem4K=">,1
    @DbgOutD [dwMaxMem4K],1
    @DbgOutS <10,"end of preallocated EMS, physical=">,1
    @DbgOutD edi,1
    @DbgOutS <10>,1
endif

;-- clear all dirty + accessed flags in page table 0

    @GETPTEPTR edx, ?PAGETAB0, 1
    mov ecx, 1000h/4
    mov al, not (20h or 40h)
@@:
    and [edx],al
    add edx, 4
    loop @B

    mov eax, ds:[ecx+06h*4]
    mov [OldInt06],eax
if ?SAFEKEYBOARD    
    mov eax, ds:[ecx+16h*4]
    mov [OldInt16],eax
endif
    mov eax, ds:[ecx+19h*4]
    mov [OldInt19],eax
    mov eax, ds:[67h*4]
    mov [OldInt67],eax

if ?VDS
    call VDS_Init
endif

;--- now clear the UMB pages and fill the UMB segment table

    movzx eax,word ptr [esi].JEMMINIT.PageMap+2
    movzx ebx,word ptr [esi].JEMMINIT.PageMap+0
    shl eax,4
    add ebx,eax

    mov ecx,0A0h
    mov edi,offset UMBsegments - size UMBBLK
    mov dl,0
@@nextitem2:
    mov al,[ebx+ecx]
    call IsShadowRAM
    jnc @@isshadow
    cmp [esi].JEMMINIT.NoRAM,0
    jnz @@skippage2
    call IsUMBMemory
    jc @@skippage2
@@isshadow:
    cmp dl,0
    jz @@newumb
if ?SPLIT
    cmp al,'8'      ;is it a SPLIT ROM?
    jb @@newumb    ;then it must be a new UMB
endif
    add [edi].UMBBLK.wSize,100h
    call clearpage
    jmp @@nextpage
@@newumb:
    add edi, size UMBBLK
    cmp edi, offset UMBsegments + UMB_MAX_BLOCKS * size UMBBLK
    jnc @@umbdone
    inc [esi].JEMMINIT.NumUMBs
    mov byte ptr [edi].UMBBLK.wSegm+1,cl
    mov [edi].UMBBLK.wSize,100h
if ?SPLIT
    call clearpageEx
else
    call clearpage
endif
    mov dl,1
    jmp @@nextpage
@@skippage2:
    mov dl,0
@@nextpage:
    inc ecx
    cmp cl,0F8h
    jb @@nextitem2
@@umbdone:
    @DbgOutS <"UMBs initialized",10>,?INITDBG

if ?MOVEHIGH
    cmp [esi].JEMMINIT.NoHigh,0   ;NOHI active?
    jnz @@nomovehigh
    mov ecx,[dwRes]
    cmp ecx,0A0000h                 ;already loaded high?
    jnc @@nomovehigh
    mov ebx, offset UMBsegments
@@anothertry:
    movzx eax,[ebx].UMBBLK.wSegm
    and eax,eax
    jz @@nomovehigh
if 0
    cmp ah,0C0h                     ;avoid to move into the video segments
    jnc @@umbok
    cmp byte ptr [ebx+size UMBBLK].UMBBLK.wSegm+1,0
    jz @@umbok
    add ebx,size UMBBLK
    jmp @@anothertry
@@umbok:
endif
    mov [esi].JEMMINIT.ResUMB,ax
    mov esi,ecx
    movzx edi,ax
    shl edi,4
    push edi
    mov ecx,rsofsinit
    movzx ecx,[ecx].RSOFS.wSizeRes
    mov eax,ecx
    rep movsb
    shr eax,4
    add [ebx].UMBBLK.wSegm,ax
    sub [ebx].UMBBLK.wSize,ax
    pop edi

    mov esi, [dwRes]
    mov [dwRes],edi
    mov eax,edi
    shr eax,4
    mov [dwRSeg],eax
    sub edi, esi
  if ?HOOK13
    add [dwRFlags],edi
  endif
    add [bpstart],edi
  if ?INTEGRATED
    add [XMS_Handle_Table.xht_pArray],edi
  endif
    @DbgOutS <"resident part moved high, seg=">,?INITDBG
    @DbgOutW ax,?INITDBG
    @DbgOutS <10>,?INITDBG
@@nomovehigh:
endif

    mov eax, [tmpFeatures]
    mov esp, ebp

if ?INITDBG
    @DbgOutS <"activating V86 mode, esp=">,1
    @DbgOutD ebp,1
    @DbgOutS <" [esp]=">,1
    @DbgOutD dword ptr [ebp+0],1
    @DbgOutC ' ',1
    @DbgOutD dword ptr [ebp+4],1
    @DbgOutC ' ',1
    @DbgOutD dword ptr [ebp+8],1
    @DbgOutS <10>,1
    @WaitKey 1,0
endif

    CLTS       ; clear TS (Task Switch) flag
               ; thus the next x87-command without INT 7 is being executed

    IRETD      ; switch to v86 mode

InitMonitor ENDP

;--- clear an UMB "page"
;--- in: ecx = page number
;--- in: al = page type, if '1' < al < '8' then split ROM
;--- in: EDI -> UMBBLK 

if ?SPLIT

clearpageEx proc
    cmp al,'8'
    jnc clearpage
    sub al,'0'  ;1,2,3,4,5,6,7
    movzx eax,al
    shl eax,5   ;20,40,60,80,A0,C0,E0
    mov byte ptr [edi].UMBBLK.wSegm,al
    sub word ptr [edi].UMBBLK.wSize,ax
    shl eax,4   ;1->200, 2->400, 3->600, 4->800, 5->A00, 6->C00, 7->E00
    push edi
    push ecx
    mov edi,ecx
    shl edi,12
    add edi,eax
    sub eax,1000h
    neg eax
    mov ecx,eax
    xor eax,eax
    rep stosd
    pop ecx
    pop edi
    ret
clearpageEx endp

endif

;--- clear a "page"
;--- in: ecx = page number

clearpage proc
    push edi
    push ecx
    mov edi,ecx
    shl edi,12
    mov ecx,1000h/4
    xor eax,eax
    rep stosd
    pop ecx
    pop edi
    ret
clearpage endp

;--- copy ROM content to a shadow page
;--- ecx = linear page to shadow (must be in region 0-3FFFFFh)
;--- edi = physical address to map

CopyROM proc
    pushad
    push ecx
    mov cl,1
    mov eax,edi
    call MapPhysPagesEx  ;map a free page in PTE heap
    pop esi
    @GETPTEPTR EBX, ?PAGETAB0+esi*4
    mov edx, [ebx]      ;get PTE for ROM page
    and edx, 0FFFh
    or edx, edi        ;copy the PTE attributes

    mov edi, eax        ;copy ROM content
    shl esi, 12
    mov ecx, 1000h/4
    rep movsd

    mov [ebx], edx      ;set PTE on old ROM location

    mov eax,cr3         ;flush TLB
    mov cr3,eax

    @DbgOutS <"PTE ">,?INITDBG
    @DbgOutD edx,?INITDBG
    @DbgOutS <" used to shadow page ">,?INITDBG
    popad
    @DbgOutD ecx,?INITDBG
    @DbgOutS <10>,?INITDBG
    ret
CopyROM endp

IsUMBMemory proc
if ?SPLIT
    cmp al,'1'
    jb @@isnotumb
    mov ah,1
    cmp al,'8'
    jb @@isumb
    dec ah
endif
    cmp al,'U'
    jz @@isumb
    cmp al,'I'
    jz @@isumb
    cmp al,'P'
    jnz @@isnotumb
    cmp [bNoFrame],0
    jz @@isnotumb
@@isumb:
    clc
    ret
@@isnotumb:
    stc
    ret
IsUMBMemory endp

IsShadowRAM proc
    cmp al,'S'
    jnz @@isnotshadow
    push ecx
    shl ecx,12
    mov ah,[ecx]
    mov byte ptr [ecx],55h
    cmp byte ptr [ecx],55h
    jnz @@isnotshadow2
    mov byte ptr [ecx],0AAh
    cmp byte ptr [ecx],0AAh
    jnz @@isnotshadow2
    mov [ecx],ah
    pop ecx
    ret
@@isnotshadow2:
    mov [ecx],ah
    pop ecx
@@isnotshadow:
    stc
    ret
IsShadowRAM endp

.text$04 ENDS

if 0
.text$04z segment FLAT public 'CODE'
V86_TOTAL equ $ - _start
.text$04z ends
endif

    END
