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

CFLAGS   := -mcpu=cortex-m23 -mthumb -Os -flto -ffunction-sections -fdata-sections \
            -fno-unwind-tables -fno-asynchronous-unwind-tables \
            -Wall -Wextra \
            -I$(DEVDIR)/Include -I$(CMSIS) -I$(STDDRV_I) -I.

LDFLAGS  := -mcpu=cortex-m23 -mthumb -flto -Wl,--gc-sections,-Map=nuc1262.map -specs=nano.specs -specs=nosys.specs -Tnuc1262.ld

SRCS     := main.c board.c it6663.c i2c1_bus.c i2c0_slave.c writer.c \
            $(DEVDIR)/Source/system_NUC1262.c \
            $(STDDRV_S)/clk.c \
            $(STDDRV_S)/sys.c \
            $(STDDRV_S)/gpio.c \
            $(STDDRV_S)/i2c.c

STARTUP  := $(DEVDIR)/Source/GCC/startup_NUC1262.S

all: nuc1262_bringup.bin nuc1262_bringup.tcl
	@$(SIZE) nuc1262_bringup.elf

nuc1262_bringup.elf: $(SRCS) $(STARTUP) $(wildcard *.h)
	$(CC) $(CFLAGS) $(LDFLAGS) $(filter %.c %.S,$^) -o $@

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@
	@test "$$(wc -c < $@)" -le 8192 || { echo "ERROR: image exceeds 8192-byte MCU staging limit" >&2; exit 1; }

nuc1262_bringup.tcl: nuc1262_bringup.bin
	python3 gen_openocd_tcl.py $< $@

clean:
	rm -f *.elf *.bin *.map *.tcl

# Pure observation/control-policy tests; no hardware access or firmware mocks.
HOSTCC ?= cc
test:
	mkdir -p ../build/tests
	$(HOSTCC) -std=c11 -O2 -Wall -Wextra -Werror -I. tests/it6663_rx_state_test.c -o ../build/tests/it6663_rx_state_test
	../build/tests/it6663_rx_state_test
	$(HOSTCC) -std=c11 -O2 -Wall -Wextra -Werror -I. tests/i2c1_plan_test.c -o ../build/tests/i2c1_plan_test
	../build/tests/i2c1_plan_test

.PHONY: all clean test
