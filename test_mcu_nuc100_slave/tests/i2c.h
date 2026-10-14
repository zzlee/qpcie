#include "NUC100Series.h"
#define I2C_I2CON_SI_AA 0x0CU
#define I2C_I2CON_STO_SI 0x18U
#define I2C_I2CON_SI 0x08U
#define I2C_SET_CONTROL_REG(i2c, value) ((i2c)->I2CON = (value))
