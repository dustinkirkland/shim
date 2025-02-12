VERSION		= 0.9
RELEASE		:=
ifneq ($(RELEASE),"")
	RELEASE="-$(RELEASE)"
endif

CC		= $(CROSS_COMPILE)gcc
LD		= $(CROSS_COMPILE)ld
OBJCOPY		= $(CROSS_COMPILE)objcopy

ARCH		= $(shell $(CC) -dumpmachine | cut -f1 -d- | sed s,i[3456789]86,ia32,)
OBJCOPY_GTE224  = $(shell expr `$(OBJCOPY) --version |grep ^"GNU objcopy" | sed 's/^.* //g' | cut -f1-2 -d.` \>= 2.24)

SUBDIRS		= Cryptlib lib

LIB_PATH	= /usr/lib64

EFI_INCLUDE	:= /usr/include/efi
EFI_INCLUDES	= -nostdinc -ICryptlib -ICryptlib/Include -I$(EFI_INCLUDE) -I$(EFI_INCLUDE)/$(ARCH) -I$(EFI_INCLUDE)/protocol -I$(shell pwd)/include
EFI_PATH	:= /usr/lib64/gnuefi

LIB_GCC		= $(shell $(CC) -print-libgcc-file-name)
EFI_LIBS	= -lefi -lgnuefi --start-group Cryptlib/libcryptlib.a Cryptlib/OpenSSL/libopenssl.a --end-group $(LIB_GCC) 

EFI_CRT_OBJS 	= $(EFI_PATH)/crt0-efi-$(ARCH).o
EFI_LDS		= elf_$(ARCH)_efi.lds

DEFAULT_LOADER	:= \\\\grub.efi
CFLAGS		= -ggdb -O0 -fno-stack-protector -fno-strict-aliasing -fpic \
		  -fshort-wchar -Wall -Wsign-compare -Werror -fno-builtin \
		  -Werror=sign-compare -ffreestanding -std=gnu89 \
		  -I$(shell $(CC) -print-file-name=include) \
		  "-DDEFAULT_LOADER=L\"$(DEFAULT_LOADER)\"" \
		  "-DDEFAULT_LOADER_CHAR=\"$(DEFAULT_LOADER)\"" \
		  $(EFI_INCLUDES)

ifneq ($(origin OVERRIDE_SECURITY_POLICY), undefined)
	CFLAGS	+= -DOVERRIDE_SECURITY_POLICY
endif

ifeq ($(ARCH),x86_64)
	CFLAGS	+= -mno-mmx -mno-sse -mno-red-zone -nostdinc \
		-maccumulate-outgoing-args \
		-DEFI_FUNCTION_WRAPPER -DGNU_EFI_USE_MS_ABI \
		"-DEFI_ARCH=L\"x64\"" \
		"-DDEBUGDIR=L\"/usr/lib/debug/usr/share/shim/x64-$(VERSION)$(RELEASE)/\""
endif
ifeq ($(ARCH),ia32)
	CFLAGS	+= -mno-mmx -mno-sse -mno-red-zone -nostdinc \
		-maccumulate-outgoing-args -m32 \
		"-DEFI_ARCH=L\"ia32\"" \
		"-DDEBUGDIR=L\"/usr/lib/debug/usr/share/shim/ia32-$(VERSION)$(RELEASE)/\""
endif
ifeq ($(ARCH),aarch64)
	CFLAGS += "-DEFI_ARCH=L\"aa64\"" \
		"-DDEBUGDIR=L\"/usr/lib/debug/usr/share/shim/aa64-$(VERSION)$(RELEASE)/\""
endif

ifneq ($(origin VENDOR_CERT_FILE), undefined)
	CFLAGS += -DVENDOR_CERT_FILE=\"$(VENDOR_CERT_FILE)\"
endif
ifneq ($(origin VENDOR_DBX_FILE), undefined)
	CFLAGS += -DVENDOR_DBX_FILE=\"$(VENDOR_DBX_FILE)\"
endif

LDFLAGS		= --hash-style=sysv -nostdlib -znocombreloc -T $(EFI_LDS) -shared -Bsymbolic -L$(EFI_PATH) -L$(LIB_PATH) -LCryptlib -LCryptlib/OpenSSL $(EFI_CRT_OBJS) --build-id=sha1

TARGET	= shim.efi MokManager.efi.signed fallback.efi.signed
OBJS	= shim.o netboot.o cert.o replacements.o version.o
KEYS	= shim_cert.h ocsp.* ca.* shim.crt shim.csr shim.p12 shim.pem shim.key shim.cer
SOURCES	= shim.c shim.h netboot.c include/PeImage.h include/wincert.h include/console.h replacements.c replacements.h version.c version.h
MOK_OBJS = MokManager.o PasswordCrypt.o crypt_blowfish.o
MOK_SOURCES = MokManager.c shim.h include/console.h PasswordCrypt.c PasswordCrypt.h crypt_blowfish.c crypt_blowfish.h
FALLBACK_OBJS = fallback.o
FALLBACK_SRCS = fallback.c

all: $(TARGET)

shim.crt:
	./make-certs shim shim@xn--u4h.net all codesign 1.3.6.1.4.1.311.10.3.1 </dev/null

shim.cer: shim.crt
	openssl x509 -outform der -in $< -out $@

shim_cert.h: shim.cer
	echo "static UINT8 shim_cert[] = {" > $@
	hexdump -v -e '1/1 "0x%02x, "' $< >> $@
	echo "};" >> $@

version.c : version.c.in
	sed	-e "s,@@VERSION@@,$(VERSION)," \
		-e "s,@@UNAME@@,$(shell uname -a)," \
		-e "s,@@COMMIT@@,$(shell if [ -d .git ] ; then git log -1 --pretty=format:%H ; elif [ -f commit ]; then cat commit ; else echo commit id not available; fi)," \
		< version.c.in > version.c

certdb/secmod.db: shim.crt
	-mkdir certdb
	pk12util -d certdb/ -i shim.p12 -W "" -K ""
	certutil -d certdb/ -A -i shim.crt -n shim -t u

shim.o: $(SOURCES) shim_cert.h

cert.o : cert.S
	$(CC) $(CFLAGS) -c -o $@ $<

shim.so: $(OBJS) Cryptlib/libcryptlib.a Cryptlib/OpenSSL/libopenssl.a lib/lib.a
	$(LD) -o $@ $(LDFLAGS) $^ $(EFI_LIBS)

fallback.o: $(FALLBACK_SRCS)

fallback.so: $(FALLBACK_OBJS) Cryptlib/libcryptlib.a Cryptlib/OpenSSL/libopenssl.a lib/lib.a
	$(LD) -o $@ $(LDFLAGS) $^ $(EFI_LIBS)

MokManager.o: $(MOK_SOURCES)

MokManager.so: $(MOK_OBJS) Cryptlib/libcryptlib.a Cryptlib/OpenSSL/libopenssl.a lib/lib.a
	$(LD) -o $@ $(LDFLAGS) $^ $(EFI_LIBS) lib/lib.a

Cryptlib/libcryptlib.a:
	$(MAKE) -C Cryptlib

Cryptlib/OpenSSL/libopenssl.a:
	$(MAKE) -C Cryptlib/OpenSSL

lib/lib.a:
	$(MAKE) CFLAGS="$(CFLAGS)" -C lib

ifeq ($(ARCH),aarch64)
FORMAT		:= -O binary
SUBSYSTEM	:= 0xa
LDFLAGS		+= --defsym=EFI_SUBSYSTEM=$(SUBSYSTEM)
endif

ifeq ($(ARCH),arm)
FORMAT		:= -O binary
SUBSYSTEM	:= 0xa
LDFLAGS		+= --defsym=EFI_SUBSYSTEM=$(SUBSYSTEM)
endif

FORMAT		?= --target efi-app-$(ARCH)

%.efi: %.so
ifneq ($(OBJCOPY_GTE224),1)
	$(error objcopy >= 2.24 is required)
endif
	$(OBJCOPY) -j .text -j .sdata -j .data \
		-j .dynamic -j .dynsym  -j .rel* \
		-j .rela* -j .reloc -j .eh_frame \
		-j .vendor_cert \
		$(FORMAT)  $^ $@
	$(OBJCOPY) -j .text -j .sdata -j .data \
		-j .dynamic -j .dynsym  -j .rel* \
		-j .rela* -j .reloc -j .eh_frame \
		-j .debug_info -j .debug_abbrev -j .debug_aranges \
		-j .debug_line -j .debug_str -j .debug_ranges \
		-j .note.gnu.build-id \
		$(FORMAT) $^ $@.debug

%.efi.signed: %.efi certdb/secmod.db
	pesign -n certdb -i $< -c "shim" -s -o $@ -f

clean:
	$(MAKE) -C Cryptlib clean
	$(MAKE) -C Cryptlib/OpenSSL clean
	$(MAKE) -C lib clean
	rm -rf $(TARGET) $(OBJS) $(MOK_OBJS) $(FALLBACK_OBJS) $(KEYS) certdb
	rm -f *.debug *.so *.efi *.tar.* version.c

GITTAG = $(VERSION)

test-archive:
	@rm -rf /tmp/shim-$(VERSION) /tmp/shim-$(VERSION)-tmp
	@mkdir -p /tmp/shim-$(VERSION)-tmp
	@git archive --format=tar $(shell git branch | awk '/^*/ { print $$2 }') | ( cd /tmp/shim-$(VERSION)-tmp/ ; tar x )
	@git diff | ( cd /tmp/shim-$(VERSION)-tmp/ ; patch -s -p1 -b -z .gitdiff )
	@mv /tmp/shim-$(VERSION)-tmp/ /tmp/shim-$(VERSION)/
	@git log -1 --pretty=format:%H > /tmp/shim-$(VERSION)/commit
	@dir=$$PWD; cd /tmp; tar -c --bzip2 -f $$dir/shim-$(VERSION).tar.bz2 shim-$(VERSION)
	@rm -rf /tmp/shim-$(VERSION)
	@echo "The archive is in shim-$(VERSION).tar.bz2"

tag:
	git tag --sign $(GITTAG) refs/heads/master

archive: tag
	@rm -rf /tmp/shim-$(VERSION) /tmp/shim-$(VERSION)-tmp
	@mkdir -p /tmp/shim-$(VERSION)-tmp
	@git archive --format=tar $(GITTAG) | ( cd /tmp/shim-$(VERSION)-tmp/ ; tar x )
	@mv /tmp/shim-$(VERSION)-tmp/ /tmp/shim-$(VERSION)/
	@git log -1 --pretty=format:%H > /tmp/shim-$(VERSION)/commit
	@dir=$$PWD; cd /tmp; tar -c --bzip2 -f $$dir/shim-$(VERSION).tar.bz2 shim-$(VERSION)
	@rm -rf /tmp/shim-$(VERSION)
	@echo "The archive is in shim-$(VERSION).tar.bz2"

export ARCH CC LD OBJCOPY EFI_INCLUDE
