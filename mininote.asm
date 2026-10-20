; =============================================================================
;  MiniNote - blocco note minimale per Windows in assembly x86 (32 bit)
;
;  Compilazione (nessun linker: l'header PE è scritto a mano qui sotto):
;      nasm -f bin mininote.asm -o mininote.exe
;
;  Funzioni: Nuovo / Apri / Salva / Salva con nome, Annulla, Taglia, Copia,
;  Incolla, Seleziona tutto, scorciatoie Ctrl+N/O/S/A e Ctrl+Maiusc+S,
;  richiesta di salvataggio delle modifiche, file da riga di comando e
;  trascinamento (drag & drop). I file sono letti in UTF-8 (con o senza BOM,
;  ripiego su ANSI se l'UTF-8 non è valido) e salvati in UTF-8; i fine riga
;  solo-LF vengono convertiti in CRLF per il controllo EDIT.
;
;  Trucchi per stare sotto i 2,5 KB:
;  - la tabella import contiene solo LoadLibraryA e GetProcAddress; le altre
;    API vengono risolte all'avvio da una lista di nomi in formato compatto;
;  - i puntatori alle API e le variabili stanno in BSS attorno a EBX, così
;    ogni chiamata è "call [ebx+disp8]" (3 byte invece di 6);
;  - finestre Unicode (API W); menu, font e messaggi usano stringhe ANSI.
; =============================================================================

bits 32

IMAGEBASE   equ 0x400000
%define RVA(x) ((x) - IMAGEBASE)

; Header all'RVA 0; sezione unica all'offset 0x200 del file e all'RVA 0x1000.
; Con vstart le etichette valgono direttamente il loro indirizzo virtuale.
section hdr start=0 vstart=IMAGEBASE

ID_NEW      equ 0x10
ID_OPEN     equ 0x11
ID_SAVE     equ 0x12
ID_SAVEAS   equ 0x13
ID_EXIT     equ 0x14
; I comandi di Modifica usano come ID il messaggio stesso da girare all'EDIT:
; WM_CUT 0x300, WM_COPY 0x301, WM_PASTE 0x302, WM_UNDO 0x304,
; EM_SETSEL 0xB1 (con lParam = -1 seleziona tutto).

EDIT_STYLE  equ 0x503001C4  ; CHILD|VISIBLE|VSCROLL|HSCROLL|MULTILINE|AUTOVSCROLL|AUTOHSCROLL|NOHIDESEL
CP_UTF8     equ 65001
WM_SETTEXT  equ 0x0C

; -----------------------------------------------------------------------------
;  Header MZ + PE
; -----------------------------------------------------------------------------
mz:
    dw  'MZ'
    times 0x3A db 0
    dd  pe - mz                 ; e_lfanew
pe:
    dd  'PE'
    dw  0x014C                  ; i386
    dw  1                       ; una sezione
    dd  0, 0, 0
    dw  opt_end - opt
    dw  0x0103                  ; RELOCS_STRIPPED | EXECUTABLE | 32BIT
opt:
    dw  0x010B                  ; PE32
    db  0, 0
    dd  raw_size                ; SizeOfCode
    dd  0, 0
    dd  RVA(start)              ; EntryPoint
    dd  0x1000, 0x1000          ; BaseOfCode, BaseOfData
    dd  IMAGEBASE
    dd  0x1000                  ; SectionAlignment
    dd  0x200                   ; FileAlignment
    dw  4, 0, 0, 0, 4, 0        ; versioni OS / immagine / sottosistema
    dd  0
    dd  0x2000                  ; SizeOfImage
    dd  0x200                   ; SizeOfHeaders
    dd  0                       ; CheckSum
    dw  2                       ; sottosistema GUI
    dw  0x8000                  ; TERMINAL_SERVER_AWARE
    dd  0x100000, 0x1000, 0x100000, 0x1000
    dd  0
    dd  2                       ; solo 2 directory: export e import
    dd  0, 0                                    ; export
    dd  RVA(import_dir), 40                     ; import
opt_end:
    db  '.text', 0, 0, 0
    dd  0x1000                  ; VirtualSize (codice + dati + bss)
    dd  0x1000                  ; VirtualAddress
    dd  raw_size
    dd  0x200                   ; PointerToRawData
    dd  0, 0
    dw  0, 0
    dd  0xE0000060              ; codice | dati | R | W | X

; Nomi per la tabella import "vera" nello spazio libero dell'header (mappato
; in sola lettura). Il descrittore e la IAT invece devono stare nella sezione:
; il loader di Windows ignora una directory import che punta dentro l'header.
hn_LoadLibraryA:
    db  0, 0, 'LoadLibraryA', 0
hn_GetProcAddress:
    db  0, 0, 'GetProcAddress', 0
dll_k32:
    db  'kernel32', 0

; Dati in sola lettura, anch'essi nello spazio libero dell'header
wc:
    dd  0, WndProc, 0, 0, IMAGEBASE, 0, 0, 6, 0, sz_titlew
accel:                              ; FVIRTKEY | FCONTROL (+ FSHIFT)
    db  9, 0
    dw  'N', ID_NEW
    db  9, 0
    dw  'O', ID_OPEN
    db  9, 0
    dw  'S', ID_SAVE
    db  13, 0
    dw  'S', ID_SAVEAS
    db  9, 0
    dw  'A', 0xB1
sz_title:   db 'MiniNote', 0
sz_edit:    dw __utf16__('EDIT'), 0
sz_font:    db 'Consolas', 0
sz_ask:     db 'Salvare le modifiche?', 0
sz_err:     db 'Impossibile aprire o salvare il file.', 0
sz_titlew:  dw __utf16__('MiniNote'), 0
sz_defext:  dw __utf16__('txt'), 0
sz_filter:  dw __utf16__('*.txt'), 0, __utf16__('*.txt'), 0
            dw __utf16__('*.*'), 0, __utf16__('*.*'), 0, 0
hdr_end:
    times 0x200 - ($ - mz) db 0     ; errore qui = l'header è pieno

; -----------------------------------------------------------------------------
;  Codice
; -----------------------------------------------------------------------------
section text start=0x200 vstart=IMAGEBASE+0x1000
text_start:

start:
    mov     ebx, BASE

    ; --- risoluzione delle API: "dll\0f1\0f2\0\0dll\0...\0\0\0" ---
    mov     esi, names
    mov     edi, apis
.dll:
    push    esi
    call    [LoadLibraryA]
    xchg    eax, ebp
    call    skipstr
.fn:
    cmp     byte [esi], 0
    je      .nextdll
    push    esi
    push    ebp
    call    [GetProcAddress]
    stosd
    call    skipstr
    jmp     .fn
.nextdll:
    inc     esi
    cmp     byte [esi], 0
    jne     .dll

    push    wc
    call    [ebx+_RegisterClassW]

    ; --- costruzione del menu dalla tabella menu_data ---
    call    [ebx+_CreateMenu]
    xchg    eax, ebp                ; ebp = barra dei menu
    mov     esi, menu_data
.mnext:
    xor     eax, eax
    lodsw
    test    eax, eax
    jz      .mdone
    cmp     ax, 0xFFFF              ; nuovo menu a tendina
    jne     .mitem
    call    [ebx+_CreatePopupMenu]
    xchg    eax, edi
    push    esi
    push    edi
    push    0x10                    ; MF_POPUP
    push    ebp
    call    [ebx+_AppendMenuA]
    jmp     .mskip
.mitem:
    cmp     ax, 0xFFFE              ; separatore
    jne     .mstr
    push    0
    push    0
    push    0x800                   ; MF_SEPARATOR
    push    edi
    call    [ebx+_AppendMenuA]
    jmp     .mnext
.mstr:
    push    esi
    push    eax
    push    0
    push    edi
    call    [ebx+_AppendMenuA]
.mskip:
    call    skipstr
    jmp     .mnext
.mdone:
    xor     edi, edi
    push    edi
    push    IMAGEBASE
    push    ebp                     ; menu
    push    edi
    mov     eax, 0x80000000         ; CW_USEDEFAULT
    push    eax
    push    eax
    push    eax
    push    eax
    push    0x10CF0000              ; WS_OVERLAPPEDWINDOW | WS_VISIBLE
    push    sz_titlew
    push    sz_titlew               ; nome della classe = titolo
    push    0x10                    ; WS_EX_ACCEPTFILES
    call    [ebx+_CreateWindowExW]

    push    5
    push    accel
    call    [ebx+_CreateAcceleratorTableW]
    mov     [ebx+V_HACC], eax

    ; --- file passato da riga di comando ---
    call    [ebx+_GetCommandLineW]
    lea     ecx, [ebx+V_ARGC]
    push    ecx
    push    eax
    call    [ebx+_CommandLineToArgvW]
    cmp     dword [ebx+V_ARGC], 2
    jb      .loop
    mov     esi, [eax+4]
    mov     edi, filebuf
.copy:
    lodsw
    stosw
    test    ax, ax
    jnz     .copy
    call    load_file
    xor     edi, edi                ; EDI = 0 per GetMessageW

.loop:
    lea     esi, [ebx+V_MSG]
    push    edi
    push    edi
    push    edi
    push    esi
    call    [ebx+_GetMessageW]
    test    eax, eax
    jz      WndProc.exit
    push    esi
    push    dword [ebx+V_HACC]
    push    dword [ebx+V_HWND]
    call    [ebx+_TranslateAcceleratorW]
    test    eax, eax
    jnz     .loop
    push    esi
    call    [ebx+_TranslateMessage]
    push    esi
    call    [ebx+_DispatchMessageW]
    jmp     .loop

skipstr:                            ; esi -> byte dopo il prossimo zero
    lodsb
    test    al, al
    jnz     skipstr
    ret

; -----------------------------------------------------------------------------
;  Procedura della finestra
; -----------------------------------------------------------------------------
WndProc:
    push    ebp
    mov     ebp, esp
    push    ebx
    push    esi
    push    edi
    mov     ebx, BASE
    xor     edi, edi
    mov     eax, [ebp+12]           ; uMsg
    cmp     eax, 1                  ; WM_CREATE
    je      .create
    cmp     eax, 5                  ; WM_SIZE
    je      .size
    cmp     eax, 7                  ; WM_SETFOCUS
    je      .focus
    cmp     eax, 0x10               ; WM_CLOSE
    je      .close
    cmp     eax, 0x111              ; WM_COMMAND
    je      .command
    cmp     eax, 0x233              ; WM_DROPFILES
    je      .drop
.default:
    pop     edi
    pop     esi
    pop     ebx
    pop     ebp
    jmp     [BASE+_DefWindowProcW]  ; chiamata in coda, argomenti già in pila

.create:
    mov     eax, [ebp+8]
    mov     [ebx+V_HWND], eax
    mov     [ofn+4], eax
    push    edi
    push    IMAGEBASE
    push    edi
    push    eax
    push    edi
    push    edi
    push    edi
    push    edi
    push    EDIT_STYLE
    push    edi
    push    sz_edit
    push    edi
    call    [ebx+_CreateWindowExW]
    mov     [ebx+V_HEDIT], eax
    xchg    eax, esi
    push    sz_font                 ; Consolas, 16 px
    push    0x31                    ; FIXED_PITCH | FF_MODERN
    push    5                       ; CLEARTYPE_QUALITY
    push    edi
    push    edi
    push    1                       ; DEFAULT_CHARSET
    push    edi
    push    edi
    push    edi
    push    400
    push    edi
    push    edi
    push    edi
    push    -16
    call    [ebx+_CreateFontA]
    push    edi
    push    eax
    push    0x30                    ; WM_SETFONT
    push    esi
    call    [ebx+_SendMessageW]
    push    edi
    push    edi
    push    0xC5                    ; EM_SETLIMITTEXT 0 = nessun limite di 32K
    push    esi
    call    [ebx+_SendMessageW]
    jmp     .ret0

.size:
    push    1
    movzx   eax, word [ebp+22]      ; altezza
    push    eax
    movzx   eax, word [ebp+20]      ; larghezza
    push    eax
    push    edi
    push    edi
    push    dword [ebx+V_HEDIT]
    call    [ebx+_MoveWindow]
    jmp     .ret0

.focus:
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SetFocus]
    jmp     .ret0

.close:
    call    ask_save
    jc      .ret0
.exit:
    push    0
    call    [BASE+_ExitProcess]

.command:
    cmp     [ebp+20], edi           ; notifiche dall'EDIT: non ci interessano
    jne     .default
    movzx   eax, word [ebp+16]
    cmp     eax, 0xB1
    jae     .editcmd
    sub     eax, ID_NEW
    je      .new
    dec     eax
    je      .open
    dec     eax
    je      .save
    dec     eax
    je      .saveas
    dec     eax
    je      .close
    jmp     .ret0

.editcmd:
    push    -1
    push    edi
    push    eax
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SendMessageW]
    jmp     .ret0

.new:
    call    ask_save
    jc      .ret0
    mov     [filebuf], di
    push    filebuf                 ; stringa vuota
    push    edi
    push    WM_SETTEXT
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SendMessageW]
    call    set_title
    jmp     .ret0

.open:
    call    ask_save
    jc      .ret0
    mov     byte [ofn+53], 0x18     ; FILEMUSTEXIST | PATHMUSTEXIST (+ HIDEREADONLY)
    push    ofn
    call    [ebx+_GetOpenFileNameW]
    test    eax, eax
    jz      .ret0
    jmp     .load

.save:
    call    do_save
    jmp     .ret0

.saveas:
    call    do_saveas
    jmp     .ret0

.drop:
    call    ask_save
    pushfd
    jc      .dfin
    push    260
    push    filebuf
    push    edi
    push    dword [ebp+16]
    call    [ebx+_DragQueryFileW]
.dfin:
    push    dword [ebp+16]
    call    [ebx+_DragFinish]
    popfd
    jc      .ret0
.load:
    call    load_file

.ret0:
    xor     eax, eax
    pop     edi
    pop     esi
    pop     ebx
    pop     ebp
    ret     16

; -----------------------------------------------------------------------------
;  ask_save: se il testo è modificato chiede se salvare. CF=1 se annullato.
; -----------------------------------------------------------------------------
ask_save:
    push    0
    push    0
    push    0xB8                    ; EM_GETMODIFY
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SendMessageW]
    test    eax, eax
    jz      .ok
    push    0x23                    ; MB_YESNOCANCEL | MB_ICONQUESTION
    push    sz_title
    push    sz_ask
    push    dword [ebx+V_HWND]
    call    [ebx+_MessageBoxA]
    cmp     al, 7                   ; IDNO
    je      .ok
    cmp     al, 2                   ; IDCANCEL
    jne     do_save                 ; IDYES
    stc
    ret
.ok:
    clc
    ret

; -----------------------------------------------------------------------------
;  do_save / do_saveas: CF=1 se annullato o fallito.
; -----------------------------------------------------------------------------
do_save:
    cmp     word [filebuf], 0
    jne     save_file
do_saveas:
    mov     byte [ofn+53], 0x08     ; PATHMUSTEXIST | OVERWRITEPROMPT | HIDEREADONLY
    push    ofn
    call    [ebx+_GetSaveFileNameW]
    test    eax, eax
    jnz     save_file
    stc
    ret

; -----------------------------------------------------------------------------
;  save_file: scrive il testo dell'EDIT in filebuf, codificato UTF-8.
; -----------------------------------------------------------------------------
save_file:
    push    0
    push    0
    push    0x0E                    ; WM_GETTEXTLENGTH
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SendMessageW]
    xchg    eax, edi                ; edi = caratteri
    lea     eax, [edi+edi*4+16]     ; 2*len (UTF-16) + 3*len (UTF-8) + margine
    push    eax
    push    0                       ; GMEM_FIXED
    call    [ebx+_GlobalAlloc]
    mov     [ebx+V_MEM], eax
    xchg    eax, esi                ; esi = buffer UTF-16
    push    esi
    lea     eax, [edi+1]
    push    eax
    push    0x0D                    ; WM_GETTEXT
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SendMessageW]
    lea     eax, [esi+edi*2+4]      ; buffer UTF-8
    push    eax                     ; (conservato per WriteFile)
    push    0
    push    0
    lea     ecx, [edi+edi*2+4]
    push    ecx
    push    eax
    push    edi
    push    esi
    push    0
    push    CP_UTF8
    call    [ebx+_WideCharToMultiByte]
    xchg    eax, edi                ; edi = byte da scrivere
    pop     esi                     ; esi = buffer UTF-8
    push    0
    push    0x80                    ; FILE_ATTRIBUTE_NORMAL
    push    2                       ; CREATE_ALWAYS
    push    0
    push    0
    push    0x40000000              ; GENERIC_WRITE
    push    filebuf
    call    [ebx+_CreateFileW]
    cmp     eax, -1
    je      .err
    push    eax                     ; argomento per CloseHandle
    push    0
    lea     ecx, [ebx+V_TMP]
    push    ecx
    push    edi
    push    esi
    push    eax
    call    [ebx+_WriteFile]
    call    [ebx+_CloseHandle]
    call    free_mem
    call    set_title
    clc
    ret
.err:
    call    free_mem
    ; prosegue in file_error

file_error:
    push    0x10                    ; MB_ICONERROR
    push    sz_title
    push    sz_err
    push    dword [ebx+V_HWND]
    call    [ebx+_MessageBoxA]
    stc
    ret

free_mem:
    push    dword [ebx+V_MEM]
    call    [ebx+_GlobalFree]
    ret

; -----------------------------------------------------------------------------
;  load_file: legge filebuf nell'EDIT (UTF-8 o ANSI, LF -> CRLF).
; -----------------------------------------------------------------------------
load_file:
    push    0
    push    0
    push    3                       ; OPEN_EXISTING
    push    0
    push    3                       ; FILE_SHARE_READ | FILE_SHARE_WRITE
    push    0x80000000              ; GENERIC_READ
    push    filebuf
    call    [ebx+_CreateFileW]
    cmp     eax, -1
    je      file_error
    xchg    eax, esi                ; esi = handle
    push    0
    push    esi
    call    [ebx+_GetFileSize]
    xchg    eax, edi                ; edi = dimensione
    lea     eax, [edi*8+16]         ; grezzo + UTF-16 + UTF-16 con CRLF
    push    eax
    push    0
    call    [ebx+_GlobalAlloc]
    mov     [ebx+V_MEM], eax
    push    0
    lea     ecx, [ebx+V_TMP]
    push    ecx
    push    edi
    push    eax
    push    esi
    call    [ebx+_ReadFile]
    push    esi
    call    [ebx+_CloseHandle]

    mov     esi, [ebx+V_MEM]
    lea     eax, [esi+edi+4]
    mov     [ebx+V_W1], eax         ; testo convertito in UTF-16
    cmp     edi, 3                  ; salta il BOM UTF-8
    jb      .nobom
    cmp     word [esi], 0xBBEF
    jne     .nobom
    cmp     byte [esi+2], 0xBF
    jne     .nobom
    add     esi, 3
    sub     edi, 3
.nobom:
    mov     ecx, CP_UTF8
    push    8                       ; MB_ERR_INVALID_CHARS
    pop     edx
    call    .conv
    test    eax, eax
    jnz     .crlf
    xor     ecx, ecx                ; UTF-8 non valido: riprova come ANSI
    xor     edx, edx
    call    .conv
.crlf:
    xchg    eax, ecx
    mov     esi, [ebx+V_W1]
    lea     edi, [esi+edi*2+4]      ; testo finale con CRLF
    push    edi
    xor     edx, edx
    jecxz   .end
.lp:
    lodsw
    cmp     ax, 10
    jne     .st
    cmp     dx, 13
    je      .st
    mov     word [edi], 13
    scasw                           ; edi += 2
.st:
    stosw
    xchg    eax, edx
    loop    .lp
.end:
    xor     eax, eax
    stosw
    pop     eax
    push    eax
    push    0
    push    WM_SETTEXT
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SendMessageW]
    call    free_mem
    ; prosegue in set_title

; -----------------------------------------------------------------------------
;  set_title: azzera il flag "modificato" e mostra il nome del file.
; -----------------------------------------------------------------------------
set_title:
    push    0
    push    0
    push    0xB9                    ; EM_SETMODIFY
    push    dword [ebx+V_HEDIT]
    call    [ebx+_SendMessageW]
    mov     eax, filebuf
    cmp     word [eax], 0
    jne     .s
    mov     eax, sz_titlew
.s:
    push    eax
    push    0
    push    WM_SETTEXT
    push    dword [ebx+V_HWND]
    call    [ebx+_SendMessageW]
    ret

load_file.conv:
    push    edi
    push    dword [ebx+V_W1]
    push    edi
    push    esi
    push    edx
    push    ecx
    call    [ebx+_MultiByteToWideChar]
    ret

; -----------------------------------------------------------------------------
;  Dati
; -----------------------------------------------------------------------------
ofn:
    dd  76, 0, 0, sz_filter, 0, 0, 1, filebuf, 260, 0, 0, 0, 0
    dd  0x806                   ; Flags (il byte +53 cambia tra Apri e Salva)
    dw  0, 0
    dd  sz_defext, 0, 0, 0

; Tabella del menu: 0xFFFF = nuova tendina, 0xFFFE = separatore, 0 = fine
menu_data:
    dw  0xFFFF
    db  '&File', 0
    dw  ID_NEW
    db  `&Nuovo\tCtrl+N`, 0
    dw  ID_OPEN
    db  `&Apri...\tCtrl+O`, 0
    dw  ID_SAVE
    db  `&Salva\tCtrl+S`, 0
    dw  ID_SAVEAS
    db  `Salva &con nome...\tCtrl+Maiusc+S`, 0
    dw  0xFFFE
    dw  ID_EXIT
    db  '&Esci', 0
    dw  0xFFFF
    db  '&Modifica', 0
    dw  0x304
    db  `&Annulla\tCtrl+Z`, 0
    dw  0xFFFE
    dw  0x300
    db  `&Taglia\tCtrl+X`, 0
    dw  0x301
    db  `&Copia\tCtrl+C`, 0
    dw  0x302
    db  `I&ncolla\tCtrl+V`, 0
    dw  0xFFFE
    dw  0xB1
    db  `Seleziona t&utto\tCtrl+A`, 0
    dw  0

; Elenco delle API: per ogni DLL il nome, poi le funzioni, poi uno zero.
; Ogni funzione F ottiene l'offset _F rispetto a EBX nella tabella "apis".
%assign NAPI 0
%macro DLL 2-*
    db  %1, 0
%rotate 1
%rep %0 - 1
%defstr %%s %1
_%1 equ NAPI * 4 - 0x80
%assign NAPI NAPI + 1
    db  %%s, 0
%rotate 1
%endrep
    db  0
%endmacro

names:
    DLL 'kernel32', CreateFileW, ReadFile, WriteFile, GetFileSize, CloseHandle, GlobalAlloc, GlobalFree, MultiByteToWideChar, WideCharToMultiByte, GetCommandLineW, ExitProcess
    DLL 'user32', RegisterClassW, CreateWindowExW, DefWindowProcW, GetMessageW, TranslateMessage, DispatchMessageW, TranslateAcceleratorW, CreateAcceleratorTableW, MoveWindow, SetFocus, SendMessageW, CreateMenu, CreatePopupMenu, AppendMenuA, MessageBoxA
    DLL 'gdi32', CreateFontA
    DLL 'comdlg32', GetOpenFileNameW, GetSaveFileNameW
    DLL 'shell32', CommandLineToArgvW, DragQueryFileW, DragFinish
    db  0

; Tabella import vera: descrittore + IAT (scrivibile)
import_dir:
    dd  0, 0, 0, RVA(dll_k32), RVA(iat)
    dd  0, 0, 0, 0, 0
iat:
LoadLibraryA:   dd RVA(hn_LoadLibraryA)
GetProcAddress: dd RVA(hn_GetProcAddress)
                dd 0

text_end:
    times (0x200 - (text_end - text_start) % 0x200) % 0x200 db 0
raw_end:
raw_size    equ raw_end - text_start

; -----------------------------------------------------------------------------
;  BSS (oltre i dati grezzi, azzerato dal loader). EBX = BASE.
; -----------------------------------------------------------------------------
apis        equ raw_end             ; NAPI puntatori a funzione
BASE        equ apis + 0x80
V_HWND      equ NAPI * 4 - 0x80
V_HEDIT     equ V_HWND + 4
V_HACC      equ V_HWND + 8
V_ARGC      equ V_HWND + 12
V_TMP       equ V_HWND + 16
V_MEM       equ V_HWND + 20
V_W1        equ V_HWND + 24
V_MSG       equ V_HWND + 28         ; MSG, 28 byte
filebuf     equ BASE + V_HWND + 56  ; 260 WCHAR
