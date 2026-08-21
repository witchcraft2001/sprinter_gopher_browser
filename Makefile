# ======================================================
# Gopher browser for Sprinter
# Build with sjasmplus. Output: build/GOPHER.EXE (DSS executable).
#
# Networking is a runtime-loaded UNET-ABI DLL (UNETESP.DLL for Wi-Fi,
# UNETRTL.DLL for NE2000/RTL8019A), selected by the env var NET (WIFI/RTL) -
# see sources/weather-forecast and sources/ftpclient for the same pattern.
# There is only one build; both DLLs ship in the distribution.
# ======================================================

ASM        := sjasmplus
SRC        := src/main.asm
# All sources main.asm pulls in, so editing any module/include forces a rebuild.
DEPS       := $(wildcard src/*.asm src/include/*.inc)
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
DIST_FILES := gopher.exe gopher.cfg index.gph unetesp.dll unetrtl.dll readme.txt readmeru.txt

# Submodules: ESP kit (DLL + unet.inc), RTL kit (DLL), libman (loader/manager).
WIFI_KIT   := extern/wifi
RTL_KIT    := extern/rtl
LIBMAN_KIT := extern/libman
ESP_DLL    := $(WIFI_KIT)/UNETESP.DLL
RTL_DLL    := $(RTL_KIT)/UNETRTL.DLL

# sjasmplus searches -I dirs in REVERSE of the order given (last wins first
# match) - list the extern kit dirs first and our own src/include/src/lib
# last, so a same-named local file (e.g. macro.inc) always shadows the kit's.
INCDIRS    := -I $(WIFI_KIT)/src/include -I $(LIBMAN_KIT)/libman -I src/include -I src/lib -I $(BUILD)
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
$(EXE): $(SRC) $(DEPS) $(HOMEPAGE) | deps $(BUILD)
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

# Copy GOPHER.EXE + both UNET DLLs onto a fresh copy of the DSS floppy template
# (under /GOPHER). NETUP.EXE (from the wifi kit) is not bundled here - it's
# expected to already be on the test image / a separate network-kit floppy.
deploy: $(EXE)
	@mkdir -p distr
	cp "$(IMG_TEMPLATE)" "$(IMG)"
	-mmd   -i "$(IMG)" ::/GOPHER 2>/dev/null
	mcopy  -i "$(IMG)" -o "$(EXE)" ::/GOPHER/GOPHER.EXE
	mcopy  -i "$(IMG)" -o "$(ESP_DLL)" ::/GOPHER/UNETESP.DLL
	mcopy  -i "$(IMG)" -o "$(RTL_DLL)" ::/GOPHER/UNETRTL.DLL
	@echo "Deployed -> $(IMG)  (run: GOPHER\\GOPHER.EXE in DSS)"

# Build a zip distribution with the files expected next to GOPHER.EXE.
dist: $(EXE) $(CFG) $(HOMEPAGE) $(DISTDIR)/readme.txt $(DISTDIR)/readmeru.txt | $(DISTDIR)
	@mkdir -p distr
	cp "$(EXE)" "$(DISTDIR)/gopher.exe"
	cp "$(CFG)" "$(DISTDIR)/gopher.cfg"
	cp "$(HOMEPAGE)" "$(DISTDIR)/index.gph"
	cp "$(ESP_DLL)" "$(DISTDIR)/unetesp.dll"
	cp "$(RTL_DLL)" "$(DISTDIR)/unetrtl.dll"
	rm -f "$(ZIP)"
	cd "$(DISTDIR)" && zip -q -r "../../$(ZIP)" $(DIST_FILES)
	@echo "Packaged -> $(ZIP)"

zip: dist

clean:
	rm -rf $(BUILD) $(IMG) $(ZIP)
