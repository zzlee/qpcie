# NUC100 APROM/LDROM firmware set (M2_710 U2).
#   stage0.bin : immutable dispatcher @0x0 (validates app, else LDROM console)
#   app.bin    : APROM app @0x0800 (header @0x0900, patched post-link)
#   ldrom.bin  : recovery console + writer @0x100000 (4KB)
#   aprom_bundle.bin : stage0 padded to 0x800 + app (single Nu-Link APROM image)
# Transition Nu-Link session: APROM <- aprom_bundle.bin @0x0,
#   LDROM <- ldrom.bin @0x100000. CONFIG untouched. Afterwards all updates
#   go through PCIe (--flash-aprom); stage0/LDROM change only via Nu-Link.
BSP      := ../raw/NUC100BSP
DEVDIR   := $(BSP)/Library/Device/Nuvoton/NUC100Series
PREFIX   := arm-none-eabi-
CC       := $(PREFIX)gcc
OBJCOPY  := $(PREFIX)objcopy
OBJDUMP  := $(PREFIX)objdump
CMSIS    := $(BSP)/Library/CMSIS/Include
STDDRV   := $(BSP)/Library/StdDriver/inc
CFLAGS   := -mcpu=cortex-m0 -mthumb -Os -ffunction-sections -fdata-sections \
            -Wall -Wextra -I$(DEVDIR)/Include -I$(CMSIS) -I$(STDDRV) -I.
SYS_SRC  := $(DEVDIR)/Source/system_NUC100Series.c
STARTUP  := $(DEVDIR)/Source/GCC/startup_NUC100Series.S
LDFLAGS  := -mcpu=cortex-m0 -mthumb -Wl,--gc-sections -specs=nosys.specs

APP_SRCS := main.c i2c_slave.c regfile.c board.c upg.c
LDROM_SRCS := ldrom_main.c i2c_slave.c upg.c writer.c
STAGE0_SRCS := stage0.c

all: stage0.bin app.bin ldrom.bin aprom_bundle.bin
	@echo "--- sizes (flash budgets: stage0<=2K app<=8K(upg staging) ldrom<=4K) ---"
	@ls -la stage0.bin app.bin ldrom.bin aprom_bundle.bin

stage0.elf: $(STAGE0_SRCS) $(STARTUP) $(SYS_SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -Tstage0.ld $^ -o $@

app.elf: $(APP_SRCS) $(STARTUP) $(SYS_SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -Tapp.ld $^ -o $@

ldrom.elf: $(LDROM_SRCS) $(STARTUP) $(SYS_SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -Tldrom.ld $^ -o $@

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@
	@ls -la $@

# Patch app header (magic/ver already linked; len + crc32 filled here).
# CRC covers [0x0800,0x0900) + [0x0910,0x0800+len); gaps are objcopy zeros,
# programmed as zero words, so both sides agree.
app.bin: app.elf
	$(OBJCOPY) -O binary $< $@
	python3 patch_app_hdr.py $@
	@ls -la $@

aprom_bundle.bin: stage0.bin app.bin
	python3 bundle_aprom.py stage0.bin app.bin $@

clean:
	rm -f *.elf *.bin *.map

.PHONY: all clean
