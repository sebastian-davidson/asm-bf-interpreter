	global _start

	section .data

ARRAYSIZE equ 16777216
CODESIZE equ 65536

errmsg	db	"Mismatched brackets!",10
ERRLEN	equ	$ - errmsg

fitmsg	db	"Error: file too big (max 65536 bytes)",10
FITLEN	equ	$ - fitmsg

	section .bss

cells	resb	ARRAYSIZE
thread	resq	CODESIZE	; The thread of instruction addresses to interpret the program.
tokens	resb	CODESIZE	; Where the original, ASCII text is read from stdin.

	section .text

; Write "Mismatched brackets!" to stdout, then exit
mismatch:
	mov	eax, 1		; write syscall no.
	mov	edi, 1		; stdout file descriptor
	lea	rsi,[rel errmsg]	; address of string
	mov	edx, ERRLEN	; length of string
	syscall
	jmp	exit_fail

toobig:	mov	eax, 1
	mov	edi, 1
	lea	rsi, [rel fitmsg]
	mov	edx, FITLEN
	syscall
	; fallthrough

exit_fail:
	mov	eax, 60
	mov	edi, 1
	syscall


; ----------- How the interpreter functions ----------------
; Each one of these functions below are the functions whose addresses
; will be in the array called "thread" declared above.
; The interpreter will start with RSI pointing to the first
; element, and RDX pointing to the first element of the Brainfuck cells.
; These are like C arrays, so we just add sizeof(element), which is 8, to get the next element.
; At the end of all of these is this:
;
;	lodsq
;	jmp	rax
;
; Which is basically the equivalent of this in C:
;
;	void *thread[CODESIZE];	// Array of pointers to functions
;	void *rax, **rsi = &thread[0];
;
;	rax = *rsi++;
;	goto *rax;
;
; You can think of it like an array of function pointers, except instead of calling
; and returning, you "call" (jump to) the subsequent function at the end of each function,
; never to return. Maybe like this:
;
;	rax = *rsi++;
;	return (*rax)();	// Any code after this is never reached,
;				// because the call never returns.


; Exit with exit code 0.
exit:	mov	eax, 60		; exit syscall no. is 60
	xor	edi, edi	; exit code 0: success
	syscall


putc:	mov	r12, rsi	; dot .
	mov	r13, rdx	; preserve registers

	mov	eax, 1		; write syscall no. is 1
	mov	edi, 1		; stdout file descriptor
	mov	rsi, rdx	; current cell address
	mov	edx, 1		; write one byte
	syscall

	mov	rsi, r12
	mov	rdx, r13
	lodsq			; mov rax, [rsi]; lea rsi, [rsi+8]
	jmp	rax


getc:	mov	r12, rsi	; comma ,
	mov	r13, rdx

	xor	eax, eax	; read syscall no. is 0
	xor	edi, edi	; stdin file descriptor is 0
	mov	rsi, rdx	; current cell address
	mov	edx, 1		; read one byte
	syscall

	mov	rsi, r12
	mov	rdx, r13
	lodsq			; rax = *(uint64_t *)rsi++;
	jmp	rax


; To branch, all we have to do is set RSI (the thread pointer)
; to a new value. After we jump to a left or right bracket instruction,
; the subsequent address is actually a pointer to a different element in the thread.
;
;	void *thread[] = {
;		...
;		brz,		// Left bracket instruction address
;		&thread[50],	// Points to the getc below
;		putc
;		...
;		brnz,		// Right bracket instruction address
;		&thread[25],	// Points to the putc above
;		getc
;		...
;	};
;
; For Brainfuck, to properly implement [ and ], the address after the left
; bracket instruction, BRZ (branch if zero), will be a pointer to the instruction
; right after ], to which it will jump if the current cell is zero.
; Likewise with the right bracket instruction, BRNZ, which jumps to the instruction
; after its corresponding [ if the current cell is not zero.
;
; RAX will be pointing to BRZ, and RSI will be pointing to the address after.
; If we don't want to branch, we skip it by adding an extra 8 bytes to RSI.
; If we do, we dereference the address stored in RSI, store it in RSI,
; and continue execution.
;


brz:	cmp	byte [rdx], 0	; left bracket [
	je	.branch

	mov	rax, [rsi + 8]	; Skip branch address, get next instruction
	add	rsi, 16
	jmp	rax

.branch	mov	rsi, [rsi]	; Set thread pointer to new address
	lodsq
	jmp	rax


brnz:	cmp	byte [rdx], 0	; right bracket ]
	jne	.branch

	mov	rax, [rsi + 8]	; Skip branch address, get next instruction
	add	rsi, 16
	jmp	rax

.branch	mov	rsi, [rsi]
	lodsq
	jmp	rax


inc_:				; right >
	add	rdx, 1
	lodsq
	jmp	rax

dec_:				; left <
	sub	rdx, 1
	lodsq
	jmp	rax

inc_ind:			; plus +
	add	byte [rdx], 1
	lodsq
	jmp	rax

dec_ind:			; minus -
	sub	byte [rdx], 1
	lodsq
	jmp	rax



_start:	cld
	mov	rbp, rsp		; initialize stack
	lea	rsi, [rel tokens]	; ptr to buf to read into
	xor	ebx, ebx		; bytes read counter = 0
	mov	edx, CODESIZE-1		; Make space for null byte terminator

.read	xor	eax, eax		; read syscall no.
	xor	edi, edi		; stdin fd
	add	rsi, rax		; read into &tokens[bytesread]
	sub	edx, eax
	syscall

	add	rbx, rax

	cmp	rbx, CODESIZE
	jae	toobig

	test	rax, rax		; number of bytes read this time
	jnz	.read			; if it's zero, we've read the whole file and hit EOF

	add	rbx, tokens		; tokens[bytesread] = '\0';
	mov	byte [rbx], 0

	lea	rcx, [rel tokens]
	lea	rdi, [rel thread]

%macro 	DISPATCH 2
	cmp	al, %1
	je	%2
%endmacro

.loop	movzx	eax, byte [rcx]
	add	rcx, 1

	DISPATCH '[', .lbra
	DISPATCH ']', .rbra
	DISPATCH '+', .plus
	DISPATCH '-', .minus
	DISPATCH '<', .left
	DISPATCH '>', .right
	DISPATCH '.', .dot
	DISPATCH ',', .comma
	DISPATCH 0, .end
	jmp	.loop		; Ignore all other chars

%macro	EMIT 1
	lea	rsi, [rel %1]
	mov	qword [rdi], rsi
	add	rdi, 8
%endmacro


.plus	EMIT	inc_ind
	jmp	.loop

.minus	EMIT	dec_ind
	jmp	.loop

.left	EMIT	dec_
	jmp	.loop

.right	EMIT	inc_
	jmp	.loop

.dot	EMIT	putc
	jmp	.loop

.comma	EMIT	getc
	jmp	.loop


.lbra	lea	rsi, [rel brz]
	mov	qword[rdi], rsi	; Emit pointer to left bracket code.
	add	rdi, 16		; Leave 8 bytes free for a pointer to fill in later.
	push	rdi		; Push ptr to subsequent instruction onto the stack.
	jmp	.loop


.rbra	cmp	rsp, rbp	; Stack empty?
	jnb	mismatch	; Then mismatched brackets (will exit)

	pop	rdx			; Pop pointer to the instr following the matching left bracket...
	lea	rsi, [rel brnz]
	mov	qword [rdi], rsi
	mov	qword [rdi + 8], rdx	; ...and emit it.
	add	rdi, 16

	sub	rdx, 8		; Point it to the branching addr of the left bracket.
	mov	qword[rdx], rdi	; Backpatch lbracket's branch addr to be the instruction after rbracket.
	jmp	.loop


.end	EMIT	exit		; End of the program, so emit the address of the exit syscall code.
	cmp	rsp, rbp	; Stack not empty?
	jb	mismatch	; Then mismatched brackets (will exit).

	lea	rsi, [rel thread]
	lea	rdx, [rel cells]
	lodsq
	jmp	rax		; Start interpretation.
