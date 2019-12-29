org 7c00h

	mov	bx, 0x0600
	mov	es, bx
	xor	di, di
	mov	si, start
	mov	cx, end-start
	repnz	movsb

	jmp	0x0000:0x0600

start:
	xor	bx, bx
	mov	es, bx
	mov	ds, bx
	mov	di, 7c00h
	mov	si, di

	xor	ah, ah
	mov	dl, 80h
	int	13h

	mov	ax, 0201h
	mov	bx, 7c00h
	mov	cx, 1
	mov	dx, 0180h
	int	13h

	jmp	0x0000:0x7c00
end:

times 0x01be - ($-$$) db 0

        db      0x80                   ; bootable partition
        db      0x01                   ; byte 0 of starting CHS
        db      0x01                   ; byte 1 of starting CHS
        db      0x00                   ; byte 2 of starting CHS
        db      0x06                   ; partition type (FAT16B)
        db      0xfe                   ; byte 0 of ending CHS
        db      0x7f                   ; byte 1 of ending CHS
        db      0x04                   ; byte 2 of ending CHS
        db      0x3f                   ; byte 0 of rel. sect. to start of part.
        db      0x00                   ; byte 1 of rel. sect. to start of part.
        db      0x00                   ; byte 2 of rel. sect. to start of part.
        db      0x00                   ; byte 3 of rel. sect. to start of part.
        db      0x86                   ; byte 0 of total sect. in part.
        db      0xfa                   ; byte 1 of total sect. in part.
        db      0x3f                   ; byte 2 of total sect. in part.
        db      0x00                   ; byte 3 of total sect. in part.

times 0x01fe - ($-$$) db 0

        db      0x55
        db      0xaa
