# ======================================================
# Moon Rabbit - Gopher browser for Sprinter
# Build with sjasmplus. Output: build/GOPHER.EXE (DSS executable).
#
# Network backend is selected at assembly time:
#   make            -> ESP Wi-Fi backend  (-DBACKEND_ESP, default)
#   make BACKEND=NE2000 -> RTL8019AS/NE2000 backend (-DBACKEND_NE2000)
# (Backends are wired in later phases; Phase 0 ignores BACKEND.)
# ======================================================

ASM        := sjasmplus
SRC        := src/main.asm
# All sources main.asm pulls in, so editing any module/include forces a rebuild.
DEPS       := $(wildcard src/*.asm src/include/*.inc)
# Home page: appended verbatim after the EXE image and the 2.2.2 passive overlay
# (the header's LOADER field makes GOPHER.EXE a loader EXE, so DSS leaves the
# file open and the program seeks to this tail at startup -- see LOAD_HOME_FILE).
# Editing it forces a rebuild.
HOMEPAGE   := data/index.gph
CFG        := data/gopher.cfg
ESP_HOWTO     := data/esp/howto.md
ESP_HOWTO_RU  := data/esp/howto_ru.md
MD2TXT        := tools/md_to_txt.pl
BUILD      := build
EXE        := $(BUILD)/GOPHER.EXE
LST        := $(BUILD)/GOPHER.lst
DISTDIR    := $(BUILD)/dist
DIST_FILES := gopher.exe gopher.cfg index.gph

BACKEND    ?= ESP

# ESP-only README docs (bundled in the dist only for the ESP backend).
ifeq ($(BACKEND),ESP)
README_TXT := $(DISTDIR)/readme.txt $(DISTDIR)/readmeru.txt
DIST_FILES += readme.txt readmeru.txt
endif

# Sprinter-WiFi network kit (ESP backend libs: isa/esplib/esp_tcp/netcfg/wcommon).
NETKIT     ?= /Users/dmitry/dev/zx/sprinter/sprinter_wifi/network
INCDIRS    := -I src/include -I src/lib -I $(BUILD) -I $(NETKIT)/src/include -I $(NETKIT)/src/lib
ASMFLAGS   := --nologo --fullpath -DBACKEND_$(BACKEND) $(INCDIRS)
# Build date/time stamped into the banner (regenerated on every (re)build).
BUILDINFO  := $(BUILD)/buildinfo.inc

# Bootable DSS floppy template used to produce a runnable test image.
IMG_TEMPLATE ?= /Users/dmitry/dev/zx/sprinter/texteditor/image/dss_image.img
IMG          := distr/gopher.img
ZIP          := distr/gopher.zip

.PHONY: all clean deploy dist zip

all: $(EXE)

$(EXE): $(SRC) $(DEPS) $(HOMEPAGE) | $(BUILD)
	@printf '\tDEFINE BUILD_DATETIME "%s"\n' "$$(date '+%d.%m.%Y %H:%M')" > "$(BUILDINFO)"
	$(ASM) $(ASMFLAGS) --lst=$(LST) --raw=$(EXE) $(SRC)
	cat "$(HOMEPAGE)" >> "$(EXE)"
	@echo "Built $(EXE) (backend: $(BACKEND)) + home page $$(wc -c < $(HOMEPAGE)) B"

$(BUILD):
	@mkdir -p $(BUILD)

$(DISTDIR):
	@mkdir -p $(DISTDIR)

$(DISTDIR)/readme.txt: $(ESP_HOWTO) $(MD2TXT) | $(DISTDIR)
	perl "$(MD2TXT)" "$<" | iconv -f UTF-8 -t CP866//TRANSLIT > "$@"

$(DISTDIR)/readmeru.txt: $(ESP_HOWTO_RU) $(MD2TXT) | $(DISTDIR)
	perl "$(MD2TXT)" "$<" | iconv -f UTF-8 -t CP866//TRANSLIT > "$@"

# Copy GOPHER.EXE onto a fresh copy of the DSS floppy template (under /GOPHER).
deploy: $(EXE)
	@mkdir -p distr
	cp "$(IMG_TEMPLATE)" "$(IMG)"
	-mmd   -i "$(IMG)" ::/GOPHER 2>/dev/null
	mcopy  -i "$(IMG)" -o "$(EXE)" ::/GOPHER/GOPHER.EXE
	@echo "Deployed -> $(IMG)  (run: GOPHER\\GOPHER.EXE in DSS)"

# Build a zip distribution with the files expected next to GOPHER.EXE.
# The howto docs are converted to CP866 plain text only for the ESP backend.
dist: $(EXE) $(CFG) $(HOMEPAGE) $(README_TXT) | $(DISTDIR)
	@mkdir -p distr
	cp "$(EXE)" "$(DISTDIR)/gopher.exe"
	cp "$(CFG)" "$(DISTDIR)/gopher.cfg"
	cp "$(HOMEPAGE)" "$(DISTDIR)/index.gph"
	rm -f "$(ZIP)"
	cd "$(DISTDIR)" && zip -q -r "../../$(ZIP)" $(DIST_FILES)
	@echo "Packaged -> $(ZIP)"

zip: dist

clean:
	rm -rf $(BUILD) $(IMG) $(ZIP)
