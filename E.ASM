	cpu     8086
	org     100h
START:
	jmp     BEGIN

TAB             EQU     9
CR              EQU     13
LF              EQU     10
FILE_TOO_BIG    DB      "File too big$"
READ_ERR_MESS   DB      "Read error$"
PROMPT_STRING   DB      "1-----",0,"2SAVE ",0,"3-----",0
		DB      "4MARK ",0,"5CUT  ",0,"6PASTE",0,"7-----",0
		DB      "8DELLN",0,"9UNDLN",0,"0QUIT ",0,0
PROMPT_LENGTH   EQU     $ - PROMPT_STRING
SAVE_MESS       DB      "Save as: ",0
DOT_$$$         DB      ".$$$",0
DOT_BAK         DB      ".BAK",0
DIRTY_BITS      DB      1
NORMAL          DB      07H
INVERSE         DB      70H
LEFT_MARGIN     DB      0
MARGIN_COUNT    DB      0
INSERT_MODE     DB      -1
MARK_MODE       DB      0
ROWS            DB      23
SAVE_COLUMN     DB      0
SAVE_ROW        DB      0
LINE_FLAG       DB      0
ALIGN 2
NAME_POINTER    DW      81H
NAME_END        DW      81H
STATUS_REG      DW      0
VIDEO_SEG       DW      0B000H
LINE_LENGTH     DW      0
UNDO_LENGTH     DW      0
CUR_POSN        DW      0
MARK_START      DW      0FFFFH
MARK_END        DW      0
MARK_HOME       DW      0
TOP_OF_SCREEN   DW      0
CURSOR          DW      0
LAST_CHAR       DW      0
COLUMNS         DW      0
PASTE_SEG       DW      0
PASTE_SIZE      DW      0
PAGE_PROC       DW      0
DISPATCH_TABLE  DW      EXIT_TO_DOS , EXIT   , EXIT_TO_DOS
		DW      MARK        , CUT    , PASTE
		DW      EXIT        , DEL_L  , UDEL_L
		DW      EXIT_TO_DOS , BAD_KEY, BAD_KEY
		DW      HOME        , UP     , PGUP
		DW      BAD_KEY     , LEFT   , BAD_KEY
		DW      RIGHT       , BAD_KEY, ENDD
		DW      DOWN        , PGDN   , EXIT_TO_DOS
		DW      DEL_CHAR

;-----------------------------------------------------------------------
; We start by initialize the display, then allocate memory for the file
; and paste segments. Parse the command line for a filename, if one was
; input, read in the file.
;-----------------------------------------------------------------------
BEGIN:
	XOR     AX, AX
	MOV     DS, AX                 ; Get a zero into DS
	MOV     AH, 12H
	MOV     BL, 10H                ; Get EGA info
	INT     10H
	MOV     AX, [0484H]            ; Get number of rows
	DEC     AL                     ; Last row is for prompt line
	MOV     [CS:ROWS], AL          ; Save the number of rows
NOT_EGA:
	MOV     AX,[044AH]             ; Get number of columns
	MOV     [CS:COLUMNS],AX        ; and store it
	MOV     AX,[0463H]             ; Address of display card
	ADD     AX,6                   ; Add six to get status port
	PUSH    CS
	POP     DS
	MOV     [STATUS_REG],AX
COLOR:
	MOV     WORD[VIDEO_SEG],0B800H ; Segment for color card
	XOR     BH,BH                  ; Use page zero
	MOV     AH,8                   ; Get current attribute
	INT     10H
	MOV     [NORMAL],AH            ; Save the normal attribute
	XOR     AH,1110111B            ; Flip the color bits
	MOV     [INVERSE],AH
MOVE_STACK:
	MOV     BX,NEW_STACK
	MOV     SP,BX                  ; Move the stack downward
	ADD     BX,BYTE 15
	MOV     CL,4                   ; Convert program size to
	SHR     BX,CL                  ; paragraphs
	MOV     AH,4AH                 ; Deallocate unused memory
	INT     21H
	MOV     BX,1000H               ; Request 64K for file segment
	MOV     AH,48H
	INT     21H
	MOV     ES,AX
	MOV     AH,48H
	INT     21H                    ; Request 64K for paste buffer
	MOV     [PASTE_SEG],AX         ; Use this for the paste buffer
GET_FILENAME:
	MOV     SI,80H                 ; Point to parameters
	MOV     CL,[SI]                ; Get number of characters
	XOR     CH,CH                  ; Make it a word
	INC     SI                     ; Point to first character
	PUSH    SI
	ADD     SI,CX                  ; Point to last character
	MOV     BYTE [SI],0            ; Make it an ASCII string
	MOV     [NAME_END],SI          ; Save pointer to last character
	POP     SI                     ; Get back pointer to filename
	CLD
	JCXZ    NO_FILENAME            ; If no params, just exit
DEL_SPACES:    
	LODSB                          ; Get character into AL
	CMP     AL," "                 ; Is it a space?
	JNE     FOUND_LETTER
	LOOP    DEL_SPACES
FOUND_LETTER:
	DEC     SI                     ; Backup pointer to first letter
	MOV     [NAME_POINTER],SI      ; Save pointer to filename
	MOV     DX,SI
	MOV     AX,3D00H               ; Setup to open file
	INT     21H
	JC      NO_FILENAME            ; If we can't open, must be new file
FILE_OPENED:
	PUSH    ES
	POP     DS                     ; DS has file segment also
	MOV     BX,AX                  ; Get the handle into BX
	XOR     DX,DX                  ; Point to file buffer
	MOV     AH,3FH                 ; Read service
	MOV     CX,0FFFEH              ; Read almost 64K bytes
	INT     21H
	MOV     DI,AX                  ; Number of bytes read in
	CMP     BYTE [DI-1],1AH        ; Was last char an EOF mark?
	JNE     NO_EOF                 ; If not, everything is OK
	DEC     DI                     ; Backup to last character
NO_EOF:
	MOV     [CS:LAST_CHAR],DI      ; Save the file size
	MOV     AH,3EH
	INT     21H                    ; Close the file
NO_FILENAME:
	PUSH    ES
	PUSH    CS
	POP     DS
	POP     DS
	CALL    REDO_PROMPT            ; Draw the prompt line

;-----------------------------------------------------------------------
; Here's the main loop.  It updates the screen, then reads a keystroke.
;-----------------------------------------------------------------------
READ_A_KEY:
	CMP     BYTE[CS:MARK_MODE],0    ;Is the mark state on?
	JE      MARK_OFF        ;If not, skip this
	OR      BYTE[CS:DIRTY_BITS],4   ;Refresh the current row
	MOV     DX,[CS:CUR_POSN]
	CMP     [CS:SAVE_ROW],DH        ;Are we on the save row?
	JE      SAME_ROW        ;If yes, then redo the row only
	MOV     BYTE[CS:DIRTY_BITS],1   ;Refresh the whole screen
SAME_ROW:
	MOV     AX,[CS:CURSOR]  ;Get cursor location
	MOV     BX,[CS:MARK_HOME]       ;Get the anchor mark position
	CMP     AX,BX           ;Moving backward in file?
	JAE     S1
	MOV     [CS:MARK_START],AX      ;Switch start and end position
	MOV     [CS:MARK_END],BX
	JMP     SHORT MARK_OFF
S1:
	MOV     [CS:MARK_END],AX        ;Store start and end marks
	MOV     [CS:MARK_START],BX
MARK_OFF:
	MOV     DX,[CS:CUR_POSN]
	MOV     [CS:SAVE_ROW],DH
	CALL    SET_CURSOR      ;Position the cursor
	TEST    BYTE[CS:DIRTY_BITS],1   ;Look at screen dirty bit
	JZ      SCREEN_OK       ;If zero, screen is OK
	MOV     AH,1            ;Get keyboard status
	INT     16H             ;Any keys ready?
	JNZ     CURRENT_OK      ;If yes, skip the update
	CALL    DISPLAY_SCREEN  ;Redraw the screen
	MOV     BYTE[CS:DIRTY_BITS],0   ;Mark screen as OK
SCREEN_OK:
	TEST    BYTE[CS:DIRTY_BITS],4   ;Is the current line dirty?
	JZ      CURRENT_OK      ;If not, take jump
	CALL    DISPLAY_CURRENT ;Redraw the current line
	MOV     BYTE[CS:DIRTY_BITS],0   ;Mark screen as OK
CURRENT_OK:
	XOR     AH,AH           ;Read the next key
	INT     16H
	OR      AL,AL           ;Is this an extended code?
	JZ      EXTENDED_CODE
	CMP     AH,0EH          ;Was it the backspace key?
	JE      BACK_SPACE
	CALL    INSERT_KEY      ;Put this character in the file
	JMP     READ_A_KEY      ;Get another key
BACK_SPACE:
	CMP     WORD[CS:CURSOR],BYTE 0  ;At start of file?
	JE      BAD_KEY         ;If at start, can't backspace
	CALL    LEFT            ;Move left one space
	CALL    DEL_CHAR        ;And delete the character
	JMP     READ_A_KEY
EXTENDED_CODE:
	CMP     AH,84H          ;Is it control PgUp?
	JNE     NOT_TOP
	CALL    TOP
	JMP     READ_A_KEY
NOT_TOP:
	CMP     AH,76H          ;Is it control PgDn?
	JNE     NOT_BOTTOM
	CALL    BOTTOM
BAD_KEY:
	JMP     READ_A_KEY
NOT_BOTTOM:
	CMP     AH,73H          ;Is it control left arrow?
	JE      SH_LEFT
	CMP     AH,74H          ;Is it control right arrow?
	JE      SH_RIGHT
	CMP     AH,53H          ;Skip high numbered keys
	JA      BAD_KEY
	XCHG    AH,AL
	SUB     AL,3BH          ;Also skip low numbered keys
	JC      BAD_KEY
	SHL     AX,1            ;Make the code an offset
	MOV     BX,AX           ;Put offset in BX
	CALL    [CS:DISPATCH_TABLE+BX] ;Call the key procedure
	JMP     READ_A_KEY      ;Then read another key

;-----------------------------------------------------------------------
; These two routines shift the display right or left to allow editing
; files which contain lines longer than 80 columns.
;-----------------------------------------------------------------------
SH_RIGHT:
	CMP     BYTE[CS:LEFT_MARGIN],255 - 8 ;Past max allowable margin?
	JAE     NO_SHIFT        ;Then can't move any more
	ADD     BYTE[CS:LEFT_MARGIN],8  ;This moves the margin over
SH_RETURN:
	CALL    CURSOR_COL      ;Compute column for cursor
	MOV     DX,[CS:CUR_POSN]
	MOV     [CS:SAVE_COLUMN],DL     ;Save the current column
	MOV     BYTE[CS:DIRTY_BITS],1   ;Redraw the screen
NO_SHIFT:
	JMP     READ_A_KEY
SH_LEFT:
	CMP     BYTE[CS:LEFT_MARGIN],0  ;At start of line already?
	JE      NO_SHIFT        ;If yes, then don't shift
	SUB     BYTE[CS:LEFT_MARGIN],8  ;Move the window over
	JMP     SHORT SH_RETURN

;-----------------------------------------------------------------------
; This moves the cursor to the top of the file.
;-----------------------------------------------------------------------
TOP:
	XOR     AX,AX           ;Get a zero into AX
	MOV     [CS:CURSOR],AX  ;Cursor to start of file
	MOV     [CS:TOP_OF_SCREEN],AX
	MOV     [CS:LEFT_MARGIN],AL     ;Move to far left margin
	MOV     BYTE[CS:DIRTY_BITS],1   ;Redraw the screen
	MOV     [CS:CUR_POSN],AX        ;Home the cursor
	MOV     [CS:SAVE_COLUMN],AL     ;Save the cursor column
	RET

;-----------------------------------------------------------------------
; This moves the cursor to the bottom of the file
;-----------------------------------------------------------------------
BOTTOM:
	MOV     DH,[CS:ROWS]            ;Get screen size
	MOV     SI,[CS:LAST_CHAR]       ;Point to last character
	MOV     BYTE[CS:LEFT_MARGIN],0  ;Set window to start of line
	CALL    LOCATE          ;Adjust the screen position
	CALL    HOME            ;Move cursor to start of line
	MOV     BYTE[CS:DIRTY_BITS],1   ;This will redraw the screen
	RET

;-----------------------------------------------------------------------
; This deletes a line, placing it in the line buffer.
;-----------------------------------------------------------------------
DEL_L:          
		MOV     BYTE[CS:LINE_FLAG],1
		CALL    FIND_START      ;Find start of this line
		MOV     [CS:CURSOR],SI  ;This will be the new cursor
		PUSH    SI              ;Save the cursor position
		CALL    FIND_NEXT       ;Find the next line
		MOV     CX,SI           ;CX will hold line length
		POP     SI              ;Get back new cursor location
DEL_END:
		SUB     CX,SI           ;Number of bytes on line
		OR      CH,CH           ;Is line too long to fit
		JZ      NOT_TOO_LONG
		MOV     CX,100H         ;Only save 256 characters
NOT_TOO_LONG:
		MOV     [CS:LINE_LENGTH],CX     ;Store length of deleted line
		JCXZ    NO_DEL_L
		MOV     DI,LINE_BUFFER ;Buffer for deleted line

		PUSH    CX
		PUSH    ES
		PUSH    CS
		POP     ES              ;Line buffer is in CSEG
		REP     MOVSB           ;Put deleted line in buffer
		POP     ES              ;Get back file segment
		POP     AX

		MOV     CX,[CS:LAST_CHAR]       ;Get the file size
		SUB     [CS:LAST_CHAR],AX       ;Subtract the deleted line
		MOV     SI,[CS:CURSOR]  ;Get new cursor location
		MOV     DI,SI
		ADD     SI,AX           ;SI points to end of file
		SUB     CX,SI           ;Length of remaining file
		JCXZ    NO_DEL_L
		REP     MOVSB           ;Shift remainder of file up
NO_DEL_L:
		MOV     DX,[CS:CUR_POSN]        ;Get cursor row/column
		MOV     SI,[CS:CURSOR]  ;Get cursor offset
		CALL    LOCATE          ;Adjust the screen position
		MOV     BYTE[CS:DIRTY_BITS],1   ;Redraw the screen
		RET

;-----------------------------------------------------------------------
; This undeletes a line by copying it from the line buffer into the file
;-----------------------------------------------------------------------
UDEL_L:
		CMP     BYTE[CS:LINE_FLAG],0    ;Is this an end of line only?
		JE      UDEL_EOL        ;If yes, don't home the cursor
		CALL    HOME            ;Move cursor to home
UDEL_EOL:
		MOV     AX,[CS:LINE_LENGTH]     ;Length of deleted line
		MOV     SI,LINE_BUFFER
		JMP     INSERT_STRING

;-----------------------------------------------------------------------
; These routines move the cursor left and right.
;-----------------------------------------------------------------------
LEFT:
		CMP     WORD[CS:CURSOR],BYTE 0  ;At start of file?
		JZ      LR_NO_CHANGE    ;Then can't move left
		MOV     DX,[CS:CUR_POSN]
		OR      DL,DL           ;At first column?
		JZ      MOVE_UP         ;If yes, then move up one
		DEC     WORD[CS:CURSOR]         ;Shift the cursor offset
LR_RETURN:
		CALL    CURSOR_COL      ;Compute column for cursor
		MOV     [CS:SAVE_COLUMN],DL     ;Save the cursor column
LR_NO_CHANGE:
		MOV     WORD[CS:UNDO_LENGTH],0
		RET
MOVE_UP:
		CALL    UP              ;Move up to next row
		JMP     SHORT ENDD      ;And move to end of line

RIGHT:
		MOV     SI,[CS:CURSOR]
		CMP     SI,[CS:LAST_CHAR]       ;At end of file?
		JE      LR_NO_CHANGE    ;If yes, then can't move
		CMP     BYTE[SI],CR    ;At end of line?
		JE      MOVE_DOWN       ;If yes, then move down
		INC     WORD[CS:CURSOR] ;Advance the cursor
		JMP     SHORT LR_RETURN
MOVE_DOWN:
		CALL    HOME            ;Move to start of line
		JMP     DOWN            ;And move down one row

;-----------------------------------------------------------------------
; This moves the cursor to the start of the current line.
;-----------------------------------------------------------------------
HOME:
		CALL    FIND_START      ;Find start of line
		MOV     [CS:CURSOR],SI  ;Save the new cursor
		MOV     BYTE[CS:SAVE_COLUMN],0  ;Save the cursor column
		MOV     BYTE[CS:CUR_POSN],0 ;Store column number
		RET

;-----------------------------------------------------------------------
; This moves the cursor to the end of the current line
;-----------------------------------------------------------------------
ENDD:
		MOV     SI,[CS:CURSOR]
		CALL    FIND_EOL        ;Find end of this line
		MOV     [CS:CURSOR],SI  ;Store the new cursor
		CALL    CURSOR_COL      ;Compute the correct column
		MOV     [CS:SAVE_COLUMN],DL     ;Save the cursor column
		RET

;-----------------------------------------------------------------------
; This moves the cursor up one row.  If the cursor is at the first row,
; the screen is scrolled down.
;-----------------------------------------------------------------------
UP:             
		MOV     WORD[CS:UNDO_LENGTH],0
		MOV     DX,[CS:CUR_POSN]
		MOV     SI,[CS:CURSOR]
		OR      DH,DH           ;At top row already?
		JZ      SCREEN_DN       ;If yes, then scroll down
		DEC     DH              ;Move cursor up one row
		CALL    FIND_CR         ;Find the beginning of this row
		MOV     [CS:CURSOR],SI
		CALL    FIND_START      ;Find start of this row
		MOV     [CS:CURSOR],SI
		CALL    SHIFT_RIGHT     ;Skip over to current column
AT_TOP:
		RET
SCREEN_DN:
		MOV     SI,[CS:TOP_OF_SCREEN]
		OR      SI,SI           ;At start of file?
		JZ      AT_TOP          ;If at top, then do nothing
		CALL    FIND_PREVIOUS   ;Find the preceeding line
		MOV     [CS:TOP_OF_SCREEN],SI;Save new top of screen
		MOV     SI,[CS:CURSOR]
		CALL    FIND_PREVIOUS   ;Find the preceeding line
		MOV     [CS:CURSOR],SI  ;This is the new cursor
SHIFT_RET:
		MOV     BYTE[CS:DIRTY_BITS],1   ;Need to redraw screen
		MOV     SI,[CS:CURSOR]
		MOV     DX,[CS:CUR_POSN]
		JMP     SHIFT_RIGHT     ;Move cursor to current column

;-----------------------------------------------------------------------
; This moves the cursor down one row.  When the last row is reached,
; the screen is shifted up one row.
;-----------------------------------------------------------------------
DOWN:
		MOV     WORD[CS:UNDO_LENGTH],0
		MOV     DX,[CS:CUR_POSN]
		CMP     DH,[CS:ROWS]            ;At bottom row already?
		MOV     SI,[CS:CURSOR]  ;Get position in file
		JE      SCREEN_UP       ;If at bottom, then scroll up
		CALL    FIND_NEXT       ;Find the start of next line
		JC      DOWN_RET        ;If no more lines, then return
		MOV     [CS:CURSOR],SI
		INC     DH              ;Advance cursor to next row
		CALL    SHIFT_RIGHT     ;Move cursor to current column
DOWN_RET:
		RET
SCREEN_UP:
		CMP     SI,[CS:LAST_CHAR]       ;Get cursor offset
		JE      DOWN_RET
		CALL    FIND_START      ;Find the start of this line
		MOV     [CS:CURSOR],SI  ;This is the new cursor
		CALL    FIND_NEXT       ;Find the offset of next line
		JC      SHIFT_RET       ;If no more lines then return
		MOV     [CS:CURSOR],SI  ;This is the new cursor
		MOV     SI,[CS:TOP_OF_SCREEN];Get the start of the top row
		CALL    FIND_NEXT       ;And find the next line
		MOV     [CS:TOP_OF_SCREEN],SI;Store the new top of screen
		JMP     SHORT SHIFT_RET

;-----------------------------------------------------------------------
; These two routines move the screen one page at a time by calling the
; UP and DOWN procedures.
;-----------------------------------------------------------------------
PGDN:   
		MOV     WORD[CS:PAGE_PROC],DOWN
PAGE_UP_DN:
		MOV     CL,[CS:ROWS]            ;Get length of the screen
		SUB     CL,5            ;Don't page a full screen
		XOR     CH,CH           ;Make it a word
PAGE_LOOP:
		PUSH    CX
		CALL    [CS:PAGE_PROC]  ;Move the cursor down
		POP     CX
		LOOP    PAGE_LOOP       ;Loop for one page length
		RET

PGUP:
		MOV     WORD[CS:PAGE_PROC],UP
		JMP     SHORT PAGE_UP_DN

;-----------------------------------------------------------------------
; This deletes the character at the cursor by shifting the remaining 
; characters forward.
;-----------------------------------------------------------------------
DEL_CHAR:
		MOV     CX,[CS:LAST_CHAR]
		MOV     SI,[CS:CURSOR]
		MOV     DI,SI
		CMP     SI,CX           ;Are we at end of file?
		JAE     NO_DEL          ;If yes, then don't delete
		LODSB
		CALL    SAVE_CHAR       ;Save it for UNDO function
		MOV     AH,[SI]         ;Look at the next character also
		PUSH    AX              ;Save character were deleting
		DEC     WORD[CS:LAST_CHAR]      ;Shorten the file by one
		SUB     CX,SI
		REP     MOVSB           ;Move file down one notch

		POP     AX              ;Get back character we deleted
		CMP     AL,CR           ;Did we delete a CR?
		JE      COMBINE
		OR      BYTE[CS:DIRTY_BITS],4   ;Current line is dirty
NO_DEL:
		RET
COMBINE:
		CMP     AH,LF           ;Was the next character a LF?
		JNE     NO_DEL_LF
		CALL    DEL_CHAR        ;Now delete the line feed
NO_DEL_LF:
		CALL    DISPLAY_BOTTOM  ;Repaint bottom of the screen
		MOV     DX,[CS:CUR_POSN]
		MOV     [CS:SAVE_COLUMN],DL     ;Save the cursor column
		RET

;-----------------------------------------------------------------------
; This toggles the mark state and resets the paste buffer pointers.
;-----------------------------------------------------------------------
MARK:
		XOR     AX,AX
		NOT     BYTE[CS:MARK_MODE];Toggle the mode flag
		CMP     [CS:MARK_MODE],AL       ;Turning mode ON?
		JNE     MARK_ON
		MOV     BYTE[CS:DIRTY_BITS],1   ;Need to redraw the screen
		MOV     WORD[CS:MARK_START],0FFFFH
		JMP     SHORT MARK_RET
MARK_ON:
		MOV     AX,[CS:CURSOR]  ;Get the cursor offset
		MOV     [CS:MARK_START],AX      ;Start of marked range
MARK_RET:
		MOV     [CS:MARK_END],  AX      ;End of marked range
		MOV     [CS:MARK_HOME], AX      ;Center of marked range
		RET

;-----------------------------------------------------------------------
; This removes the marked text and places it in the paste buffer
;-----------------------------------------------------------------------
CUT:
		CMP     BYTE[CS:MARK_MODE],0    ;Is the mark mode on?
		JE      NO_MARK         ;If not, then do nothing
		MOV     CX,[CS:MARK_END]        ;Get end of mark region
		MOV     SI,[CS:MARK_START]      ;Get start of mark region
		SUB     CX,SI           ;Number of bytes selected
		MOV     [CS:PASTE_SIZE],CX
		JCXZ    NO_MARK
		XOR     DI,DI           ;Point to paste bufferf

		PUSH    CX
		PUSH    ES
		MOV     ES,[CS:PASTE_SEG]       ;Get the paste segment
		REP     MOVSB           ;Put deleted text in buffer
		POP     ES
		POP     AX

		MOV     CX,[CS:LAST_CHAR]
		SUB     [CS:LAST_CHAR],AX       ;Shorten the file this much
		MOV     DI,[CS:MARK_START]
		MOV     SI,[CS:MARK_END]
		SUB     CX,SI
		JCXZ    NO_DELETE
		REP     MOVSB           ;Shorten the file
NO_DELETE:
		MOV     DX,[CS:CUR_POSN]
		MOV     SI,[CS:MARK_START]
		CALL    LOCATE          ;Adjust the screen position
		CALL    MARK            ;This turns off select
NO_MARK:
		RET

;-----------------------------------------------------------------------
; This copies the paste buffer into the file at the cursor location
;-----------------------------------------------------------------------
PASTE:
		MOV     AX,[CS:PASTE_SIZE]      ;Number of characters in buffer
		OR      AX,AX           ;Any there?
		JZ      NO_PASTE        ;If not, nothing to paste
		MOV     SI,[CS:CURSOR]  ;Get cursor location
		PUSH    AX
		PUSH    SI
		CALL    OPEN_SPACE      ;Make room for new characters
		POP     DI
		POP     CX
		JC      NO_PASTE        ;If no room, just exit
		XOR     SI,SI           ;Point to paste buffer
		PUSH    DS
		MOV     DS,[CS:PASTE_SEG]       ;Segment of paste buffer
		REP     MOVSB           ;Copy in the new characters
		POP     DS
		MOV     SI,DI
		MOV     [CS:CURSOR],SI  ;Cursor moved to end of insert
		MOV     DX,[CS:CUR_POSN]        ;Get current cursor row
		CALL    LOCATE          ;Adjust the screen position
		MOV     BYTE[CS:DIRTY_BITS],1   ;Redraw the screen
NO_PASTE:
		RET

;-----------------------------------------------------------------------
; This inserts AX characters from CS:SI into the file.
;-----------------------------------------------------------------------
INSERT_STRING:
		PUSH    SI              ;Save string buffer
		MOV     SI,[CS:CURSOR]  ;Get cursor offset
		PUSH    AX              ;Save length of string
		PUSH    SI
		CALL    OPEN_SPACE      ;Make space to insert string
		POP     DI              ;Get back cursor position
		POP     CX              ;Get back string length
		POP     SI              ;Get back string buffer
		JC      NO_SPACE        ;If no space available, exit

		PUSH    DS
		PUSH    CS
		POP     DS
		REP     MOVSB           ;Copy the characters in
		MOV     SI,[CURSOR]     ;Get the new cursor offset
		MOV     DX,[CUR_POSN]   ;Also get the current row
		MOV     BYTE[DIRTY_BITS],1      ;And redraw the screen
		POP     DS
		CALL    LOCATE          ;Adjust the screen position
NO_SPACE:
		RET

;-----------------------------------------------------------------------
; This adds a character to the undo buffer.
;-----------------------------------------------------------------------
SAVE_CHAR:
		MOV     BX,[CS:UNDO_LENGTH]
		OR      BH,BH           ;Is buffer filled?
		JNZ     NO_SAVE
		INC     WORD[CS:UNDO_LENGTH]
		MOV     BYTE[CS:UNDO_BUFFER+BX],AL
NO_SAVE:
		RET

;-----------------------------------------------------------------------
; This prompts for a verify keystroke then exits without saving the file
;-----------------------------------------------------------------------
EXIT_TO_DOS:
	mov     ax, 3
	int     0x10
	mov     ax, 0x4C00
	int     0x21

;-----------------------------------------------------------------------
; This prompts for a filename then writes the file.  The original file
; is renamed to filename.BAK.  If an invalid filename is entered, the 
; speaker is beeped.
;-----------------------------------------------------------------------
EXIT:
		PUSH    DS
		PUSH    ES
		MOV     AX,CS
		MOV     DS,AX
		MOV     ES,AX
NEXT_LETTER:
		MOV     DH,[ROWS]
		INC     DH              ;Last row on the screen
		XOR     DL,DL           ;First column
		MOV     SI,SAVE_MESS
		PUSH    DX
		CALL    TTY_STRING      ;Display a prompt
		POP     DX
		ADD     DL,9            ;Move right 9 spaces
		MOV     SI,[NAME_POINTER]
		CALL    TTY_STRING      ;Display the filename

		XOR     AH,AH           ;Read the next key
		INT     16H
		MOV     DI,[NAME_END]   ;This points to last letter
		OR      AL,AL           ;Is it a real character?
		JZ      NEXT_LETTER     ;Ignore special keys
		CMP     AL,27           ;Is it escape?
		JNE     NOT_ESCAPE

		MOV     BYTE[DIRTY_BITS],1      ;Redraw the screen
		POP     ES              ;Get back file segments
		POP     DS
		JMP     REDO_PROMPT       ;Redraw the prompt
NOT_ESCAPE:
		CMP     AL,13             ;Is it CR?
		JE      GOT_NAME
		CMP     AL,8              ;Is it a backspace?
		JNE     NORMAL_LETTER
		CMP     DI,[NAME_POINTER] ;At first letter?
		JLE     NEXT_LETTER       ;If yes, dont erase it
		MOV     BYTE[DI-1],0
		DEC     WORD[NAME_END]
		JMP     SHORT NEXT_LETTER
NORMAL_LETTER:
		CMP     DI,81H + 65       ;Too many letters?
		JG      NEXT_LETTER       ;If yes, ignore them
		XOR     AH,AH
		STOSW                     ;Store the new letter
		INC     WORD[NAME_END]    ;Name is one character longer
		JMP     SHORT NEXT_LETTER ;Read another keystroke
GOT_NAME:
		MOV     DX,[NAME_POINTER] ;Point to the filename
		MOV     AX,4300H          ;Get the files attribute
		INT     21H
		JNC     NAME_OK           ;If no error, filename is OK
		CMP     AX,3              ;Was it path not found error?
		JE      BAD_NAME          ;If yes, filename was bad
NAME_OK:
		MOV     SI,DOT_$$$        ;Point to the ".$$$"
		MOV     DI,NAME_DOT_$$$
		CALL    CHG_EXTENSION     ;Add the new extension

		MOV     DX,NAME_DOT_$$$   ;Point to the temp filename
		MOV     AH,3CH            ;Function to create file
		MOV     CX,0020H          ;Attribute for new file
		INT     21H               ;Try to create the file
		JNC     NAME_WAS_OK       ;Continue if name was OK
BAD_NAME:
		MOV     AX,0E07H          ;Write a bell character
		INT     10H               ;BIOS tty service
		JMP     NEXT_LETTER       ;Get another letter
WRITE_ERROR:
		MOV     AH,3EH            ;Close the file
		INT     21H
		JMP     SHORT BAD_NAME    ;Filename must be bad
NAME_WAS_OK:
		XOR     DX,DX             ;This is the file buffer
		MOV     CX,[LAST_CHAR]    ;Number of chars in file
		MOV     DI,CX
		MOV     BX,AX             ;This is the handle
		MOV     AH,40H            ;Write to the file
		POP     DS                ;Recover buffer segment
		CMP     CX,BYTE -1        ;Is buffer already full?
		JE      DONT_ADD_EOF      ;If yes, dont add EOF mark
		INC     CX                ;Plus one character for EOF mark
		MOV     BYTE [DI],1AH     ;Add the EOF marker
DONT_ADD_EOF:
		INT     21H               ;Write the buffer contents
		POP     DS
		JC      WRITE_ERROR       ;Exit on a write error
		CMP     AX,CX             ;Was entire file written?
		JNE     WRITE_ERROR       ;If not, exit

		PUSH    CS
		POP     DS                ;Get the code segment
		MOV     AH,3EH
		INT     21H               ;Close the temp file
		MOV     SI,DOT_BAK        ;Point to the ".BAK"
		MOV     DI,NAME_DOT_BAK
		CALL    CHG_EXTENSION     ;Make the backup filename

		MOV     DX,NAME_DOT_BAK   ;Point to the backup name
		MOV     AH,41H
		INT     21H               ;Delete existing backup file
		MOV     DI,NAME_DOT_BAK
		MOV     DX,[NAME_POINTER]
		MOV     AH,56H
		INT     21H
					  
		MOV     DI,[NAME_POINTER] ;Point to new filename
		MOV     DX,NAME_DOT_$$$   ;Point to temporary file
		MOV     AH,56H            ;Rename temp to new file
		INT     21H               ;DOS function to rename
		POP     AX                ;Restore the stack
		POP     AX
		JMP     EXIT_TO_DOS

;-----------------------------------------------------------------------
; This subroutine displays a character by writing directly
; to the screen buffer.
;-----------------------------------------------------------------------
WRITE_INVERSE:
		MOV     BH,[CS:INVERSE]     ; Attribute for inverse video
		JMP     SHORT WRITE_SCREEN
WRITE_NORMAL:
		MOV     BH,[CS:NORMAL]      ; Attribute for normal video
WRITE_SCREEN:
		MOV     BL,AL               ; Save the character
		PUSH    ES
		MOV     DX,[CS:STATUS_REG]  ; Retrieve status register
		MOV     ES,[CS:VIDEO_SEG]   ; Get segment of video buffer
WRITE_IT:
		MOV     AX,BX               ; Get the character/attribute
		STOSW                       ; Write the character
		POP     ES
		RET

;-----------------------------------------------------------------------
; This moves the cursor to the row/column in DX.
;-----------------------------------------------------------------------
SET_CURSOR:
		XOR     BH,BH               ; Were using page zero
		MOV     AH,2                ; BIOS set cursor function
		INT     10H
		RET

;-----------------------------------------------------------------------
; This computes the video buffer offset for the row/column in DX
;----------------------------------------------------------------------
POSITION:
		MOV     AX,[CS:COLUMNS]     ; Take columns per row
		MUL     DH                  ; Times row number
		XOR     DH,DH
		ADD     AX,DX               ; Add in the column number
		SHL     AX,1                ; Times 2 for offset
		MOV     DI,AX               ; Return result in DI
		RET

;-----------------------------------------------------------------------
; This erases from the location in DX to the right edge of the screen
;-----------------------------------------------------------------------
ERASE_EOL:
		CALL    POSITION            ; Find screen offset
		MOV     CX,[CS:COLUMNS]     ; Get screen size
		SUB     CL,DL               ; Subtract current position
		JCXZ    NO_CLEAR
ERASE_LOOP:
		MOV     AL," "              ; Write blanks to erase
		CALL    WRITE_NORMAL        ; Display it
		LOOP    ERASE_LOOP
NO_CLEAR:       RET

;-----------------------------------------------------------------------
; This displays the function key prompt and insert mode state
;-----------------------------------------------------------------------
REDO_PROMPT:
		PUSH    DS
		PUSH    CS
		POP     DS
		MOV     DH,[ROWS]           ; Put prompt at last row
		INC     DH
		XOR     DL,DL               ; And column 0
		CALL    POSITION            ; Convert to screen offset
		MOV     SI,PROMPT_STRING
KEY_LOOP:
		MOV     AL,"F"              ; Display an "F"
		CALL    WRITE_NORMAL
		LODSB
		OR      AL,AL               ; Last key in prompt?
		JZ      PROMPT_DONE
		CALL    WRITE_NORMAL

		CMP     BYTE [CS:SI],"0"    ; Is it F10?
		JNE     TEXT_LOOP
		LODSB
		CALL    WRITE_NORMAL
TEXT_LOOP:
		LODSB
		OR      AL,AL               ; Last letter in word?
		JNZ     WRITE_CHAR

		MOV     AL," "              ; Display a space
		CALL    WRITE_NORMAL
		JMP     SHORT KEY_LOOP
WRITE_CHAR:
		CALL    WRITE_INVERSE       ; Display the letter
		JMP     SHORT TEXT_LOOP     ; Do the next letter
PROMPT_DONE:
		POP     DS
		RET

;-----------------------------------------------------------------------
; This displays the file buffer on the screen.
;-----------------------------------------------------------------------
DISPLAY_SCREEN:
		MOV     SI,[CS:TOP_OF_SCREEN];Point to first char on screen
		XOR     DH,DH           ;Start at first row
		JMP     SHORT NEXT_ROW
DISPLAY_BOTTOM:                         ;This redraws the bottom only
		CALL    FIND_START      ;Find first character on this row
		MOV     DX,[CS:CUR_POSN]        ;Get current cursor row
NEXT_ROW:
		PUSH    DX
		CALL    DISPLAY_LINE    ;Display a line
		POP     DX
		INC     DH              ;Move to the next row
		CMP     DH,[CS:ROWS]    ;At end of screen yet?
		JBE     NEXT_ROW        ;Do all the rows
		RET

;-----------------------------------------------------------------------
; This subroutine displays a single line to the screen. DH holds the 
; row number, SI has the offset into the file buffer. Tabs are expanded.
; Adjustment is made for side shift.
;-----------------------------------------------------------------------
DISPLAY_CURRENT:
	CALL    FIND_START
	MOV     DX,[CS:CUR_POSN]
DISPLAY_LINE:
	XOR     DL,DL           ;Start at column zero
	MOV     [CS:MARGIN_COUNT],DL
	MOV     CX,DX           ;Use CL to count the columns
	CALL    POSITION        ;Compute offset into video
NEXT_CHAR:
	CMP     SI,[CS:LAST_CHAR]       ;At end of file?
	JAE     LINE_DONE
	LODSB                   ;Get next character
	CMP     AL,CR           ;Is it a carriage return?
	JE      FOUND_CR        ;Quit when a CR is found
	CMP     AL,TAB          ;Is this a Tab character
	JE      EXPAND_TAB      ;If yes, expand to spaces
	CALL    PUT_CHAR        ;Put character onto screen
TAB_DONE:
	CMP     CL,BYTE[CS:COLUMNS]     ;At right edge of screen?
	JB      NEXT_CHAR
	CMP     BYTE[SI],CR;Is this the end of the line?
	JE      NOT_BEYOUND
	DEC     DI              ;Backup one character
	DEC     DI
	MOV     AL,4            ;Show a diamond
	CALL    WRITE_INVERSE   ;In inverse video
NOT_BEYOUND:
	JMP     FIND_NEXT       ;Find start of next line
FOUND_CR:
	LODSB                   ;Look at the next character
	CMP     AL,LF           ;Is it a line feed?
	JE      LINE_DONE
	DEC     SI
LINE_DONE:
	MOV     DX,CX
	JMP     ERASE_EOL       ;Erase the rest of the line
EXPAND_TAB:
	MOV     AL," "          ;Convert Tabs to spaces
	CALL    PUT_CHAR
	MOV     AL,[CS:MARGIN_COUNT]
	ADD     AL,CL
	TEST    AL,00000111B    ;At even multiple of eight?
	JNZ     EXPAND_TAB      ;If not keep adding spaces
	JMP     SHORT TAB_DONE

;-----------------------------------------------------------------------
; This displays a single character to the screen.  If the character is 
; marked, it is shown in inverse video.  Characters outside the current
; margin are not displayed. Characters left of the margin are skipped.
;-----------------------------------------------------------------------
PUT_CHAR:
	MOV     BL,[CS:MARGIN_COUNT]    ;Get distance to left margin
	CMP     BL,[CS:LEFT_MARGIN]     ;Are we inside left margin?
	JAE     IN_WINDOW       ;If yes, show the character
	INC     BL
	MOV     [CS:MARGIN_COUNT],BL
	RET
IN_WINDOW:
	CMP     SI,[CS:MARK_START]      ;Is this character marked?
	JBE     NOT_MARKED
	CMP     SI,[CS:MARK_END]
	JA      NOT_MARKED
	CALL    WRITE_INVERSE   ;Marked characters shown inverse
	JMP     SHORT NEXT_COL
NOT_MARKED:
	CALL    WRITE_NORMAL
NEXT_COL:
	INC     CL              ;Increment the column count
	RET

;-----------------------------------------------------------------------
; This routine adds a character into the file.  In insert mode, remaining
; characters are pushed forward. If a CR is inserted, a LF is added also.
;-----------------------------------------------------------------------
INSERT_KEY:
	MOV     SI,[CS:CURSOR]
	CMP     AL,CR           ;Was this a carriage return
	JE      NEW_LINE
	MOV     SI,[CS:CURSOR]
	CMP     BYTE[CS:INSERT_MODE],0  ;In insert mode?
	JNE     INSERT_CHAR
	CMP     BYTE [SI],CR;At end of line?
	JE      INSERT_CHAR
	CMP     SI,[CS:LAST_CHAR]       ;At end of file?
	JE      INSERT_CHAR
	MOV     DI,SI
	XCHG    [SI],AL         ;Switch new character for old one
	CALL    SAVE_CHAR       ;Store the old character
	JMP     SHORT ADVANCE
INSERT_CHAR:
	PUSH    SI
	PUSH    AX              ;Save the new character
	MOV     AX,1
	CALL    OPEN_SPACE      ;Make room for it
	POP     AX              ;Get back the new character
	POP     DI
	JC      FILE_FULL
	STOSB                   ;Insert character in file buffer
ADVANCE:
	OR      BYTE[CS:DIRTY_BITS],4   ;Current line is dirty
	PUSH    WORD[CS:UNDO_LENGTH]
	CALL    RIGHT           ;Move cursor to next letter
	POP     WORD[CS:UNDO_LENGTH]
FILE_FULL:
	RET
NEW_LINE:
	PUSH    SI
	MOV     AX,2
	CALL    OPEN_SPACE      ;Make space for CR and LF
	POP     DI              ;Get back old cursor location
	JC      FILE_FULL
	MOV     AX,LF*256+CR
	STOSW                   ;Store the CR and LF
	CALL    DISPLAY_BOTTOM  ;Repaint bottom of the screen
	CALL    HOME            ;Cursor to start of line
	JMP     DOWN            ;Move down to the new line

;-----------------------------------------------------------------------
; This subroutine inserts spaces into the file buffer.  On entry AX
; contains the number of spaces to be inserted.  On return, CF=1 if
; there was not enough space in the file buffer.
;-----------------------------------------------------------------------
OPEN_SPACE:
	MOV     CX,[CS:LAST_CHAR]      ; Last character in the file
	MOV     SI,CX
	MOV     DI,CX
	ADD     DI,AX                  ; Offset for new end of file
	JC      NO_ROOM                ; If no more room, return error
	MOV     [CS:LAST_CHAR],DI      ; Save offset of end of file
	SUB     CX,[CS:CURSOR]         ; Number of characters to shift
	DEC     DI
	DEC     SI
	STD                            ; String moves goes forward
	REP     MOVSB                  ; Shift the file upward
	CLD
	CLC
NO_ROOM:
	RET

;-----------------------------------------------------------------------
; This subroutine adjusts the cursor position ahead to the saved cursor
; column.  On entry DH has the cursor row.
;-----------------------------------------------------------------------
SHIFT_RIGHT:
	MOV     CL,[CS:SAVE_COLUMN]    ; Keep the saved cursor offset
	XOR     CH,CH
	MOV     BP,CX                  ; Keep the saved cursor position
	ADD     CL,[CS:LEFT_MARGIN]    ; Shift into visable window also
	ADC     CH,0
	XOR     DL,DL
	MOV     [CS:CUR_POSN],DX       ; Get cursor row/column
	JCXZ    NO_CHANGE
RIGHT_AGAIN:
	PUSH    CX
	CMP     BYTE [SI],CR           ; At end of line?
	JE      DONT_MOVE              ; If at end, stop moving
	CALL    RIGHT                  ; Move right one character
DONT_MOVE:
	POP     CX
	MOV     AL,[CS:SAVE_COLUMN]
	XOR     AH,AH
	CMP     AX,CX                  ; Is cursor still in margin?
	JL      IN_MARGIN              ; If yes, keep moving
	MOV     DX,[CS:CUR_POSN]       ; Get cursor column again
	XOR     DH,DH
	CMP     DX,BP                  ; At saved cursor position?
	JE      RIGHT_DONE             ; If yes, were done
	JA      RIGHT_TOO_FAR          ; Did we go too far?
IN_MARGIN:
	LOOP    RIGHT_AGAIN
RIGHT_DONE:
	MOV     CX,BP
	MOV     [CS:SAVE_COLUMN],CL    ; Get back saved cursor position
NO_CHANGE:
	RET
RIGHT_TOO_FAR:
	CALL    LEFT                   ; Move back left one place
	MOV     CX,BP
	MOV     [CS:SAVE_COLUMN],CL    ; Get back saved cursor position
	RET

;-----------------------------------------------------------------------
; This subroutine skips past the CR and LF at SI.  SI returns new offset
;-----------------------------------------------------------------------
SKIP_CR_LF:
	CMP     SI,[CS:LAST_CHAR]      ; At last char in the file?
	JAE     NO_SKIP                ; If yes, dont skip anything
	CMP     BYTE [SI],CR           ; Is first character a CR?
	JNE     NO_SKIP
	INC     SI                     ; Look at next character
	CMP     SI,[CS:LAST_CHAR]      ; Is it at the end of file?
	JAE     NO_SKIP                ; If yes, dont skip anymore
	CMP     BYTE [SI],LF           ; Is next character a line feed?
	JNE     NO_SKIP                ; Skip any line feeds also
	INC     SI
NO_SKIP:
	RET

;-----------------------------------------------------------------------
; This subroutine finds the beginning of the previous line.
;-----------------------------------------------------------------------
FIND_PREVIOUS:
	PUSH    WORD[CS:CURSOR]        ; Save the cursor location
	CALL    FIND_CR                ; Find start of this line
	MOV     [CS:CURSOR],SI         ; Save the new cursor
	CALL    FIND_START             ; Find the start of this line
	POP     WORD[CS:CURSOR]        ; Get back starting cursor
	RET

;-----------------------------------------------------------------------
; This searches for the previous carriage return.  Search starts at SI.
;-----------------------------------------------------------------------
FIND_CR:
	PUSH    CX
	MOV     AL,CR                  ; Look for a carriage return
	MOV     DI,SI
	MOV     CX,SI
	JCXZ    AT_BEGINNING
	DEC     DI
	STD                            ; Search backwards
	REPNE   SCASB                  ; Scan for the character
	CLD                            ; Restore direction flag
	INC     DI
	MOV     SI,DI
AT_BEGINNING:
	POP     CX
	RET

;-----------------------------------------------------------------------
; This subroutine computes the location of the start of current line.
; Returns SI pointing to the first character of the current line.
;-----------------------------------------------------------------------
FIND_START:
	MOV     SI,[CS:CURSOR]         ; Get the current cursor
	OR      SI,SI                  ; At start of the file?
	JZ      AT_START               ; If yes, were done
	CALL    FIND_CR                ; Find the 
	CALL    SKIP_CR_LF
AT_START:
	RET

;-----------------------------------------------------------------------
; This finds the offset of the start of the next line.  The search is 
; started at location ES:SI.  On return CF=1 of no CR was found.
;-----------------------------------------------------------------------
FIND_NEXT:
	PUSH    CX
	CALL    FIND_EOL               ; Find the end of this line
	JC      AT_NEXT                ; If at end of file, return
	CALL    SKIP_CR_LF             ; Skip past CR and LF
	CLC                            ; Indicate end of line found
AT_NEXT:                  
	POP     CX
	RET

;-----------------------------------------------------------------------
; This searches for the next carriage return in the file.  The search
; starts at the offset in register SI.
;-----------------------------------------------------------------------
FIND_EOL:
	MOV     AL,CR                  ; Look for a carriage return
	MOV     CX,[CS:LAST_CHAR]      ; Last letter in the file
	SUB     CX,SI                  ; Count for the search
	MOV     DI,SI
	JCXZ    AT_END                 ; If nothing to search, return
	REPNE   SCASB                  ; Scan for the character
	MOV     SI,DI                  ; Return the location of the CR
	JCXZ    AT_END                 ; If not found, return
	DEC     SI
	CLC                            ; Indicate the CR was found
	RET
AT_END:
	STC                            ; Indicate CR was not found
	RET

;-----------------------------------------------------------------------
; This subroutine positions the screen with the cursor at the row
; selected in register DH.  On entry, SI holds the cursor offset.
;-----------------------------------------------------------------------
LOCATE:
	MOV     CL,DH
	XOR     CH,CH
	MOV     [CS:CURSOR],SI
	XOR     DX,DX                  ; Start at top of the screen
	OR      SI,SI                  ; At start of buffer?
	JZ      LOCATE_FIRST
	CALL    FIND_START             ; Get start of this row
	XOR     DX,DX                  ; Start at top of the screen
	OR      SI,SI                  ; Is cursor at start of file?
	JZ      LOCATE_FIRST
	JCXZ    LOCATE_FIRST           ; If locating to top row were done
FIND_TOP:
	PUSH    SI
	PUSH    CX
	CALL    FIND_CR                ; Find previous row
	POP     CX
	POP     AX
	CMP     BYTE [SI],CR
	JNE     LOCATE_FIRST
	CMP     SI,AX                  ; Did it change?
	JE      LOCATE_DONE            ; If not, quit moving
	INC     DH                     ; Cursor moves to next row
	LOOP    FIND_TOP
LOCATE_DONE:
	PUSH    WORD[CS:CURSOR]
	MOV     [CS:CURSOR],SI
	CALL    FIND_START             ; Find start of top of screen
	POP     WORD[CS:CURSOR]
LOCATE_FIRST:
	MOV     [CS:TOP_OF_SCREEN],SI
	MOV     [CS:CUR_POSN],DX
	CALL    CURSOR_COL
	MOV     [CS:SAVE_COLUMN],DL
	RET

;-----------------------------------------------------------------------
; This subroutine computes the correct column for the cursor.  No
; inputs.  On exit, CUR_POSN is set and DX has the row/column.
;-----------------------------------------------------------------------
CURSOR_COL:
	MOV     SI,[CS:CURSOR]         ; Get cursor offset
	CALL    FIND_START             ; Find start of this line
	MOV     CX,[CS:CURSOR]
	SUB     CX,SI
	MOV     DX,[CS:CUR_POSN]       ; Get current row
	XOR     DL,DL                  ; Start at column zero
	MOV     [CS:MARGIN_COUNT],DL   ; Count past the left margin
	JCXZ    COL_DONE
CURSOR_LOOP:
	LODSB                          ; Get the next character
	CMP     AL,CR                  ; Is it the end of line?
	JE      COL_DONE               ; If end, were done
	CMP     AL,TAB                 ; Is it a tab?
	JNE     NOT_A_TAB
	MOV     BL,[CS:MARGIN_COUNT]
	OR      BL,00000111B
	MOV     [CS:MARGIN_COUNT],BL
	CMP     BL,[CS:LEFT_MARGIN]    ; Inside visible window yet?
	JB      NOT_A_TAB              ; If not, don't advance cursor
	OR      DL,00000111B           ; Move to multiple of eight
NOT_A_TAB:
	MOV     BL,[CS:MARGIN_COUNT]
	INC     BL
	MOV     [CS:MARGIN_COUNT],BL
	CMP     BL,[CS:LEFT_MARGIN]
	JBE     OUT_OF_WINDOW
	INC     DL                     ; Were at next column now
OUT_OF_WINDOW:
	LOOP    CURSOR_LOOP
COL_DONE:
	CMP     DL,BYTE[CS:COLUMNS]    ; Past end of display?
	JB      COLUMN_OK              ; If not, were OK?
	MOV     DL,BYTE[CS:COLUMNS]
	DEC     DL                     ; Leave cursor at last column
COLUMN_OK:
	MOV     [CS:CUR_POSN],DX       ; Store the row/column
	RET

;-----------------------------------------------------------------------
; This displays the string at CS:SI at the location in DX.  The 
; remainder of the row is erased.  Cursor is put at the end of the line.
;-----------------------------------------------------------------------
TTY_STRING:
	PUSH    DX
	CALL    POSITION               ; Compute offset into video
	POP     DX
TTY_LOOP:
	LODSB
	OR      AL,AL                  ; At end of string yet?
	JZ      TTY_DONE
	INC     DL
	PUSH    DX
	CALL    WRITE_INVERSE          ; Write in inverse video
	POP     DX
	JMP     SHORT TTY_LOOP
TTY_DONE:
	CALL    SET_CURSOR             ; Move cursor to end of string
	JMP     ERASE_EOL              ; Erase the rest of line

;-----------------------------------------------------------------------
; This copies the input filename to CS:DI and changes the extension
;-----------------------------------------------------------------------
CHG_EXTENSION:
	PUSH    SI
	MOV     SI,[NAME_POINTER]
CHG_LOOP:
	LODSB           
	CMP     AL,"."                 ; Look for the extension
	JE      FOUND_DOT
	OR      AL,AL
	JZ      FOUND_DOT
	STOSB                          ; Copy a character
	JMP     SHORT CHG_LOOP
FOUND_DOT:
	MOV     CX,5                   ; Five chars in extension
	POP     SI
	REP     MOVSB                  ; Move new extension in
	RET

align 2

NAME_DOT_$$$    EQU     $
NAME_DOT_BAK    EQU     $ + 80H
UNDO_BUFFER     EQU     $ + 100H
LINE_BUFFER     EQU     $ + 200H
NEW_STACK       EQU     $ + 500H
