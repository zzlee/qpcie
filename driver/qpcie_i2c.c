// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * File: qpcie_i2c.c
 * Description: Linux Kernel I2C Adapter Driver for QPCIe Front-End I2C Bus.
 *              Provides standard Linux /dev/i2c-X interface and IT68051 status query.
 */

#include "qpcie_driver.h"

#define I2C_TIMEOUT_US      20000 /* 20 ms timeout per byte */

static inline u32 qpcie_i2c_read(struct qpcie_dev *qdev, u32 reg)
{
    return ioread32(qdev->bar1_mmio + BAR1_OFFSET_I2C + reg);
}

static inline void qpcie_i2c_write(struct qpcie_dev *qdev, u32 reg, u32 val)
{
    iowrite32(val, qdev->bar1_mmio + BAR1_OFFSET_I2C + reg);
}

static int qpcie_i2c_wait_tip(struct qpcie_dev *qdev)
{
    unsigned long timeout = jiffies + usecs_to_jiffies(I2C_TIMEOUT_US);

    while (time_before(jiffies, timeout)) {
        u32 sr = qpcie_i2c_read(qdev, REG_I2C_SR);
        if (!(sr & I2C_SR_TIP))
            return 0;
        usleep_range(50, 100);
    }

    dev_err(&qdev->pdev->dev, "I2C timeout waiting for TIP to clear\n");
    return -ETIMEDOUT;
}

static int qpcie_i2c_send_byte(struct qpcie_dev *qdev, u8 byte, u32 cr_flags)
{
    int ret;

    qpcie_i2c_write(qdev, REG_I2C_TXR, byte);
    qpcie_i2c_write(qdev, REG_I2C_CR, cr_flags | I2C_CR_WR);

    ret = qpcie_i2c_wait_tip(qdev);
    if (ret)
        return ret;

    /* Check RXACK (0 = ACK, 1 = NACK) */
    if (qpcie_i2c_read(qdev, REG_I2C_SR) & I2C_SR_RXACK)
        return -ENXIO; /* NACK from slave */

    return 0;
}

static int qpcie_i2c_recv_byte(struct qpcie_dev *qdev, u8 *byte, bool last_byte, bool send_stop)
{
    int ret;
    u32 cr = I2C_CR_RD;

    if (last_byte)
        cr |= I2C_CR_ACK; /* Send NACK on last read byte */
    if (send_stop)
        cr |= I2C_CR_STO;

    qpcie_i2c_write(qdev, REG_I2C_CR, cr);

    ret = qpcie_i2c_wait_tip(qdev);
    if (ret)
        return ret;

    *byte = (u8)(qpcie_i2c_read(qdev, REG_I2C_RXR) & 0xFF);
    return 0;
}

static int qpcie_i2c_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
    struct qpcie_dev *qdev = i2c_get_adapdata(adap);
    int i, j, ret = 0;

    mutex_lock(&qdev->i2c_lock);

    for (i = 0; i < num; i++) {
        struct i2c_msg *msg = &msgs[i];
        bool is_read = (msg->flags & I2C_M_RD) != 0;
        bool is_last_msg = (i == num - 1);
        u8 addr_byte = (msg->addr << 1) | (is_read ? 1 : 0);

        /* Send START + Address */
        ret = qpcie_i2c_send_byte(qdev, addr_byte, I2C_CR_STA);
        if (ret) {
            /* Address NACK or bus error: Send STOP */
            qpcie_i2c_write(qdev, REG_I2C_CR, I2C_CR_STO);
            qpcie_i2c_wait_tip(qdev);
            goto out;
        }

        if (is_read) {
            for (j = 0; j < msg->len; j++) {
                bool is_last_byte = (j == msg->len - 1);
                bool send_stop = is_last_byte && is_last_msg;

                ret = qpcie_i2c_recv_byte(qdev, &msg->buf[j], is_last_byte, send_stop);
                if (ret)
                    goto out;
            }
        } else {
            for (j = 0; j < msg->len; j++) {
                bool is_last_byte = (j == msg->len - 1);
                u32 cr = 0;

                if (is_last_byte && is_last_msg)
                    cr |= I2C_CR_STO;

                ret = qpcie_i2c_send_byte(qdev, msg->buf[j], cr);
                if (ret) {
                    qpcie_i2c_write(qdev, REG_I2C_CR, I2C_CR_STO);
                    qpcie_i2c_wait_tip(qdev);
                    goto out;
                }
            }
        }
    }

    ret = num;

out:
    mutex_unlock(&qdev->i2c_lock);
    return ret;
}

static u32 qpcie_i2c_func(struct i2c_adapter *adap)
{
    return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm qpcie_i2c_algo = {
    .master_xfer   = qpcie_i2c_xfer,
    .functionality = qpcie_i2c_func,
};

/* IT68051 HDMI Receiver Status Query (I2C Addr 0x48) */
int qpcie_it68051_get_status(struct qpcie_dev *qdev, u32 *width, u32 *height, u32 *fps, bool *locked)
{
    u8 reg_addr = 0x0D; /* System Status / Cable detect */
    u8 status_val = 0;
    u8 h_buf[2], v_buf[2];
    struct i2c_msg msgs[2];
    int ret;

    if (!qdev->i2c_registered)
        return -ENODEV;

    /* 1. Check Cable & Clock Lock on IT68051 (0x48) */
    msgs[0].addr = 0x48;
    msgs[0].flags = 0;
    msgs[0].len = 1;
    msgs[0].buf = &reg_addr;

    msgs[1].addr = 0x48;
    msgs[1].flags = I2C_M_RD;
    msgs[1].len = 1;
    msgs[1].buf = &status_val;

    ret = i2c_transfer(&qdev->i2c_adap, msgs, 2);
    if (ret != 2) {
        *locked = false;
        *width = 0;
        *height = 0;
        *fps = 0;
        return -ENXIO;
    }

    /* Bit 0 = 5V Detected, Bit 1 = Clock Locked (SCDT) */
    *locked = ((status_val & 0x03) == 0x03);

    if (!*locked) {
        *width = 0;
        *height = 0;
        *fps = 0;
        return 0;
    }

    /* 2. Read HActive (Registers 0x98, 0x99) */
    reg_addr = 0x98;
    msgs[0].buf = &reg_addr;
    msgs[1].len = 2;
    msgs[1].buf = h_buf;
    ret = i2c_transfer(&qdev->i2c_adap, msgs, 2);
    if (ret == 2) {
        *width = ((u32)(h_buf[1] & 0x1F) << 8) | h_buf[0];
    } else {
        *width = 1920; /* Default fallback */
    }

    /* 3. Read VActive (Registers 0x9A, 0x9B) */
    reg_addr = 0x9A;
    msgs[0].buf = &reg_addr;
    msgs[1].len = 2;
    msgs[1].buf = v_buf;
    ret = i2c_transfer(&qdev->i2c_adap, msgs, 2);
    if (ret == 2) {
        *height = ((u32)(v_buf[1] & 0x0F) << 8) | v_buf[0];
    } else {
        *height = 1080;
    }

    *fps = 60;
    return 0;
}

int qpcie_i2c_init(struct qpcie_dev *qdev)
{
    int ret;

    mutex_init(&qdev->i2c_lock);

    /* Check if BAR1 is mapped */
    if (!qdev->bar1_mmio) {
        dev_warn(&qdev->pdev->dev, "BAR1 MMIO not available, skipping I2C\n");
        return -ENODEV;
    }

    /* Configure I2C Prescaler: 100 kHz @ 125 MHz clock (PRER = 249 = 0x00F9) */
    qpcie_i2c_write(qdev, REG_I2C_PRER_LO, 249 & 0xFF);
    qpcie_i2c_write(qdev, REG_I2C_PRER_HI, (249 >> 8) & 0xFF);

    /* Enable I2C Core */
    qpcie_i2c_write(qdev, REG_I2C_CTR, I2C_CTR_EN);

    /* Setup i2c_adapter */
    qdev->i2c_adap.owner = THIS_MODULE;
    qdev->i2c_adap.algo = &qpcie_i2c_algo;
    qdev->i2c_adap.dev.parent = &qdev->pdev->dev;
    snprintf(qdev->i2c_adap.name, sizeof(qdev->i2c_adap.name), "qpcie-i2c-%s",
             pci_name(qdev->pdev));
    i2c_set_adapdata(&qdev->i2c_adap, qdev);

    ret = i2c_add_adapter(&qdev->i2c_adap);
    if (ret) {
        dev_err(&qdev->pdev->dev, "Failed to register I2C adapter: %d\n", ret);
        return ret;
    }

    qdev->i2c_registered = true;
    dev_info(&qdev->pdev->dev, "Registered I2C bus: %s (adapter %d)\n",
             qdev->i2c_adap.name, qdev->i2c_adap.nr);

    return 0;
}

void qpcie_i2c_remove(struct qpcie_dev *qdev)
{
    if (qdev->i2c_registered) {
        i2c_del_adapter(&qdev->i2c_adap);
        qdev->i2c_registered = false;
        dev_info(&qdev->pdev->dev, "Unregistered I2C adapter\n");
    }
}
