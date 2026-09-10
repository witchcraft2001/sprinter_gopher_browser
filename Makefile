# ======================================================
# Gopher browser for Sprinter
# Build with sjasmplus. Output: build/GOPHER.EXE (DSS executable).
#
# Networking is a runtime-loaded UNETLD backend. NET selects UNET<TAG>.DLL;
# WIFI remains the compatibility alias for UNETESP.DLL.
# ======================================================

ASM        := sjasmplus
SRC        := src/main.asm
# All sources main.asm pulls in, so editing any module/include forces a rebuild.
DEPS       := $(wildcard src/*.asm src/include/*.inc)
UNET_DEPS  = $(wildcard $(UNET_KIT)/include/*.asm $(UNET_CORE)/bindings/asm/*.inc $(LIBMAN_KIT)/libman/*.asm $(LIBMAN_KIT)/libman/*.inc)
# Home page: appended verbatim after the EXE image (the header's LOADER field
# makes GOPHER.EXE a loader EXE, so DSS leaves the file open and the program
# seeks to this tail at startup -- see LOAD_HOME_FILE). Editing it forces a rebuild.
HOMEPAGE   := data/index.gph
CFG        := data/gopher.cfg
ESP_HOWTO     := data/esp/howto.md
ESP_HOWTO_RU  := data/esp/howto_ru.md
MD2TXT        := tools/md_to_txt.pl
CHECK_DEPS    := tools/check_deps.py
BUILD      := build
EXE        := $(BUILD)/GOPHER.EXE
LST        := $(BUILD)/GOPHER.lst
DISTDIR    := $(BUILD)/dist
DIST_FILES = gopher.exe gopher.cfg index.gph $(notdir $(UNET_DLLS)) readme.txt readmeru.txt

# One consumer binding owns the generic loader, generated ABI, vendored DLL
# manifest and nested libman dependency.
UNET_KIT   := extern/unet_libs_asm
UNET_CORE  := $(UNET_KIT)/extern/core
LIBMAN_KIT := $(UNET_KIT)/extern/libman
UNET_DLLS  := $(wildcard $(UNET_CORE)/dll/UNET*.DLL)

# sjasmplus searches -I dirs in REVERSE of the order given (last wins first
# match) - list the extern kit dirs first and our own src/include/src/lib
# last, so a same-named local file (e.g. macro.inc) always shadows the kit's.
INCDIRS    := -I $(UNET_KIT)/include -I $(UNET_CORE)/bindings/asm -I $(LIBMAN_KIT)/libman -I src/include -I src/lib -I $(BUILD)
ASMFLAGS   := --nologo --fullpath $(INCDIRS)
# Build date/time stamped into the banner (regenerated on every (re)build).
BUILDINFO  := $(BUILD)/buildinfo.inc

# Bootable DSS floppy template used to produce a runnable test image.
IMG_TEMPLATE ?= /Users/dmitry/dev/zx/sprinter/texteditor/image/dss_image.img
IMG          := distr/gopher.img
ZIP          := distr/gopher.zip

.PHONY: all deps clean deploy dist zip

all: $(EXE)

# Verify submodule pins + DLL identity before building (see tools/check_deps.py).
deps:
	python3 "$(CHECK_DEPS)"

# deps is order-only: it must run (and can fail the build), but being .PHONY
# it would force a re-assembly on every make if listed as a normal prerequisite.
$(EXE): $(SRC) $(DEPS) $(UNET_DEPS) $(HOMEPAGE) | deps $(BUILD)
	@printf '\tDEFINE BUILD_DATETIME "%s"\n' "$$(date '+%d.%m.%Y %H:%M')" > "$(BUILDINFO)"
	$(ASM) $(ASMFLAGS) --lst=$(LST) --raw=$(EXE) $(SRC)
	cat "$(HOMEPAGE)" >> "$(EXE)"
	@echo "Built $(EXE) + home page $$(wc -c < $(HOMEPAGE)) B"

$(BUILD):
	@mkdir -p $(BUILD)

$(DISTDIR):
	@mkdir -p $(DISTDIR)

$(DISTDIR)/readme.txt: $(ESP_HOWTO) $(MD2TXT) | $(DISTDIR)
	perl "$(MD2TXT)" "$<" | iconv -f UTF-8 -t CP866//TRANSLIT > "$@"

$(DISTDIR)/readmeru.txt: $(ESP_HOWTO_RU) $(MD2TXT) | $(DISTDIR)
	perl "$(MD2TXT)" "$<" | iconv -f UTF-8 -t CP866//TRANSLIT > "$@"

# Copy GOPHER.EXE + every manifest-listed UNET DLL onto a fresh DSS floppy
# (under /GOPHER). Backend bring-up utilities are not bundled here - they are
# expected to already be on the test image / a separate network-kit floppy.
deploy: $(EXE)
	@mkdir -p distr
	cp "$(IMG_TEMPLATE)" "$(IMG)"
	-mmd   -i "$(IMG)" ::/GOPHER 2>/dev/null
	mcopy  -i "$(IMG)" -o "$(EXE)" ::/GOPHER/GOPHER.EXE
	@for dll in $(UNET_DLLS); do \
		mcopy -i "$(IMG)" -o "$$dll" ::/GOPHER/$$(basename "$$dll"); \
	done
	@echo "Deployed -> $(IMG)  (run: GOPHER\\GOPHER.EXE in DSS)"

# Build a zip distribution with the files expected next to GOPHER.EXE.
dist: $(EXE) $(CFG) $(HOMEPAGE) $(DISTDIR)/readme.txt $(DISTDIR)/readmeru.txt | $(DISTDIR)
	@mkdir -p distr
	cp "$(EXE)" "$(DISTDIR)/gopher.exe"
	cp "$(CFG)" "$(DISTDIR)/gopher.cfg"
	cp "$(HOMEPAGE)" "$(DISTDIR)/index.gph"
	cp $(UNET_DLLS) "$(DISTDIR)/"
	rm -f "$(ZIP)"
	cd "$(DISTDIR)" && zip -q -r "../../$(ZIP)" $(DIST_FILES)
	@echo "Packaged -> $(ZIP)"

zip: dist

clean:
	rm -rf $(BUILD) $(IMG) $(ZIP)
