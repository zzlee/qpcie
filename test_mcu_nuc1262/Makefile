# SPDX-License-Identifier: Apache-2.0
# NUC1262 Bringup Firmware for SC7F0 N1 HDMI2 V11

BSP      := ../raw/NUC1262BSP
DEVDIR   := $(BSP)/Library/Device/Nuvoton/NUC1262
CMSIS    := $(BSP)/Library/CMSIS/Include
STDDRV_I := $(BSP)/Library/StdDriver/inc
STDDRV_S := $(BSP)/Library/StdDriver/src

PREFIX   := arm-none-eabi-
CC       := $(PREFIX)gcc
OBJCOPY  := $(PREFIX)objcopy
OBJDUMP  := $(PREFIX)objdump
SIZE     := $(PREFIX)size

CFLAGS   := -mcpu=cortex-m23 -mthumb -Os -ffunction-sections -fdata-sections \
            -Wall -Wextra \
            -I$(DEVDIR)/Include -I$(CMSIS) -I$(STDDRV_I) -I.

LDFLAGS  := -mcpu=cortex-m23 -mthumb -Wl,--gc-sections -specs=nosys.specs -Tnuc1262.ld

SRCS     := main.c board.c it6663.c i2c0_slave.c writer.c \
            $(DEVDIR)/Source/system_NUC1262.c \
            $(STDDRV_S)/clk.c \
            $(STDDRV_S)/sys.c \
            $(STDDRV_S)/gpio.c \
            $(STDDRV_S)/i2c.c

STARTUP  := $(DEVDIR)/Source/GCC/startup_NUC1262.S

all: nuc1262_bringup.bin nuc1262_bringup.tcl
	@$(SIZE) nuc1262_bringup.elf

nuc1262_bringup.elf: $(SRCS) $(STARTUP)
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

nuc1262_bringup.tcl: nuc1262_bringup.bin
	python3 gen_openocd_tcl.py $< $@

clean:
	rm -f *.elf *.bin *.map *.tcl

.PHONY: all clean
