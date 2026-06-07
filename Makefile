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
BUILD      := build
EXE        := $(BUILD)/GOPHER.EXE
LST        := $(BUILD)/GOPHER.lst

BACKEND    ?= ESP

# Sprinter-WiFi network kit (ESP backend libs: isa/esplib/esp_tcp/netcfg/wcommon).
NETKIT     ?= /Users/dmitry/dev/zx/sprinter/sprinter_wifi/network
INCDIRS    := -I src/include -I src/lib -I $(NETKIT)/src/include -I $(NETKIT)/src/lib
ASMFLAGS   := --nologo --fullpath -DBACKEND_$(BACKEND) $(INCDIRS)

# Bootable DSS floppy template used to produce a runnable test image.
IMG_TEMPLATE ?= /Users/dmitry/dev/zx/sprinter/texteditor/image/dss_image.img
IMG          := distr/gopher.img

.PHONY: all clean deploy

all: $(EXE)

$(EXE): $(SRC) $(DEPS) | $(BUILD)
	$(ASM) $(ASMFLAGS) --lst=$(LST) --raw=$(EXE) $(SRC)
	@echo "Built $(EXE) (backend: $(BACKEND))"

$(BUILD):
	@mkdir -p $(BUILD)

# Copy GOPHER.EXE onto a fresh copy of the DSS floppy template (under /GOPHER).
deploy: $(EXE)
	@mkdir -p distr
	cp "$(IMG_TEMPLATE)" "$(IMG)"
	-mmd   -i "$(IMG)" ::/GOPHER 2>/dev/null
	mcopy  -i "$(IMG)" -o "$(EXE)" ::/GOPHER/GOPHER.EXE
	@echo "Deployed -> $(IMG)  (run: GOPHER\\GOPHER.EXE in DSS)"

clean:
	rm -rf $(BUILD) $(IMG)
