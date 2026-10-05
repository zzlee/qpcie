# Minimal NUC100 firmware build (needs gcc-arm-none-eabi)
BSP      := ../raw/NUC100BSP
DEVDIR   := $(BSP)/Library/Device/Nuvoton/NUC100Series
PREFIX   := arm-none-eabi-
CC       := $(PREFIX)gcc
OBJCOPY  := $(PREFIX)objcopy
CMSIS    := $(BSP)/Library/CMSIS/Include
STDDRV   := $(BSP)/Library/StdDriver/inc
CFLAGS   := -mcpu=cortex-m0 -mthumb -Os -ffunction-sections -fdata-sections \
            -Wall -I$(DEVDIR)/Include -I$(CMSIS) -I$(STDDRV) -I.
SYS_SRC  := $(DEVDIR)/Source/system_NUC100Series.c
STARTUP  := $(DEVDIR)/Source/GCC/startup_NUC100Series.S
LDFLAGS  := -mcpu=cortex-m0 -mthumb -Wl,--gc-sections -specs=nosys.specs \
            -T$(DEVDIR)/Source/GCC/gcc_arm.ld

all: mcu_minimal.bin

mcu_minimal.elf: main.c $(STARTUP) $(SYS_SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

mcu_minimal.bin: mcu_minimal.elf
	$(OBJCOPY) -O binary $< $@
	@ls -la $@

clean:
	rm -f mcu_minimal.elf mcu_minimal.bin
