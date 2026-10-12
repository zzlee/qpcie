# Minimal NUC100 I2C-slave firmware (M2_710 U2, APROM)
BSP      := ../raw/NUC100BSP
DEVDIR   := $(BSP)/Library/Device/Nuvoton/NUC100Series
PREFIX   := arm-none-eabi-
CC       := $(PREFIX)gcc
OBJCOPY  := $(PREFIX)objcopy
CMSIS    := $(BSP)/Library/CMSIS/Include
STDDRV   := $(BSP)/Library/StdDriver/inc
CFLAGS   := -mcpu=cortex-m0 -mthumb -Os -ffunction-sections -fdata-sections \
            -Wall -Wextra -I$(DEVDIR)/Include -I$(CMSIS) -I$(STDDRV) -I.
SYS_SRC  := $(DEVDIR)/Source/system_NUC100Series.c
STARTUP  := $(DEVDIR)/Source/GCC/startup_NUC100Series.S
LDFLAGS  := -mcpu=cortex-m0 -mthumb -Wl,--gc-sections -specs=nosys.specs \
            -T$(DEVDIR)/Source/GCC/gcc_arm.ld

# Set I2CSEL=I2C1 to build the PA.10/PA.11 variant if SDA_MCU is wired there.
I2CSEL   ?= I2C0
ifeq ($(I2CSEL),I2C1)
CFLAGS   += -DUSE_I2C1
TARGET   := mcu_nuc100_slave_i2c1
else
TARGET   := mcu_nuc100_slave_i2c0
endif

all: $(TARGET).bin

$(TARGET).elf: main.c $(STARTUP) $(SYS_SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@
	@ls -la $@

clean:
	rm -f mcu_nuc100_slave_i2c0.elf mcu_nuc100_slave_i2c0.bin \
	      mcu_nuc100_slave_i2c1.elf mcu_nuc100_slave_i2c1.bin
