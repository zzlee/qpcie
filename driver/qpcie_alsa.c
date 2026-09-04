// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Driver: qpcie_alsa.c
 * Description: ALSA Sound Card Driver for Custom PCIe AES3 Multi-Channel Audio.
 *              - Channel 0: Card 2 (Pattern Gen Capture Source, Device 0 Capture)
 *              - Channels 1..3: Cards 3..5 (Loopback Channels, Device 0 Playback, Device 1 Capture)
 */

#include "qpcie_driver.h"
#include <linux/ktime.h>
#include <linux/hrtimer.h>

static const struct snd_pcm_hardware qpcie_alsa_hardware = {
    .info = (SNDRV_PCM_INFO_MMAP |
             SNDRV_PCM_INFO_INTERLEAVED |
             SNDRV_PCM_INFO_BLOCK_TRANSFER |
             SNDRV_PCM_INFO_MMAP_VALID),
    .formats            = SNDRV_PCM_FMTBIT_S32_LE | SNDRV_PCM_FMTBIT_S24_LE,
    .rates              = SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_96000,
    .rate_min           = 48000,
    .rate_max           = 96000,
    .channels_min       = 2,
    .channels_max       = 8,
    .buffer_bytes_max   = 128 * 1024,
    .period_bytes_min   = 4 * 1024,
    .period_bytes_max   = 32 * 1024,
    .periods_min        = 2,
    .periods_max        = 16,
};

/* ========================================================================= */
/* ALSA Capture Stream Callbacks (C2H DMA Engine)                            */
/* ========================================================================= */

static int qpcie_alsa_cap_open(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct snd_pcm_runtime *runtime = substream->runtime;

    ach->cap_substream = substream;
    runtime->hw = qpcie_alsa_hardware;
    return 0;
}

static int qpcie_alsa_cap_close(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    ach->cap_substream = NULL;
    return 0;
}

static int qpcie_alsa_hw_params(struct snd_pcm_substream *substream, struct snd_pcm_hw_params *hw_params)
{
    return 0;
}

static int qpcie_alsa_hw_free(struct snd_pcm_substream *substream)
{
    return 0;
}

static int qpcie_alsa_cap_prepare(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    dma_addr_t dma_addr = substream->runtime->dma_addr;
    size_t buffer_bytes = snd_pcm_lib_buffer_bytes(substream);
    size_t period_bytes = snd_pcm_lib_period_bytes(substream);

    ach->cap_buffer_pos = 0;

    // Backward compatibility for Ch0 registers
    if (ach->channel_id == 0) {
        iowrite32(lower_32_bits(dma_addr), qdev->bar0_mmio + REG_AUDIO_DMA_ADDR_L);
        iowrite32(upper_32_bits(dma_addr), qdev->bar0_mmio + REG_AUDIO_DMA_ADDR_H);
        iowrite32(((u32)period_bytes << 16) | ((u32)buffer_bytes & 0xFFFF),
                  qdev->bar0_mmio + REG_AUDIO_DMA_CFG);
    }

    // Program channel-specific C2H DMA address and config (0x100..0x13C)
    iowrite32(lower_32_bits(dma_addr), qdev->bar0_mmio + REG_AUDIO_DMA_ADDR_CH_L(ach->channel_id));
    iowrite32(upper_32_bits(dma_addr), qdev->bar0_mmio + REG_AUDIO_DMA_ADDR_CH_H(ach->channel_id));
    iowrite32(((u32)period_bytes << 16) | ((u32)buffer_bytes & 0xFFFF),
              qdev->bar0_mmio + REG_AUDIO_DMA_CFG_CH(ach->channel_id));

    dev_info(&qdev->pdev->dev,
             "[ALSA Ch%d Capture Prepare] DMA=0x%llX, buffer=%zu bytes, period=%zu bytes\n",
             ach->channel_id, (u64)dma_addr, buffer_bytes, period_bytes);
    return 0;
}

static int qpcie_alsa_cap_trigger(struct snd_pcm_substream *substream, int cmd)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    u32 ctrl;

    switch (cmd) {
    case SNDRV_PCM_TRIGGER_START:
        ctrl = ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
        iowrite32(ctrl | DMA_CTRL_AUDIO_RUN_CH(ach->channel_id), qdev->bar0_mmio + REG_DMA_CTRL);
        dev_info(&qdev->pdev->dev, "[ALSA Ch%d Capture] Started (DMA_CTRL=0x%08X)\n",
                 ach->channel_id, (u32)(ctrl | DMA_CTRL_AUDIO_RUN_CH(ach->channel_id)));
        break;
    case SNDRV_PCM_TRIGGER_STOP:
        ctrl = ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
        iowrite32(ctrl & ~DMA_CTRL_AUDIO_RUN_CH(ach->channel_id), qdev->bar0_mmio + REG_DMA_CTRL);
        dev_info(&qdev->pdev->dev, "[ALSA Ch%d Capture] Stopped\n", ach->channel_id);
        break;
    default:
        return -EINVAL;
    }
    return 0;
}

static snd_pcm_uframes_t qpcie_alsa_cap_pointer(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    u32 hw_pos;
    size_t buf_bytes = snd_pcm_lib_buffer_bytes(substream);

    hw_pos = ioread32(qdev->bar0_mmio + REG_AUDIO_DMA_PTR_CH(ach->channel_id));
    if (hw_pos >= buf_bytes)
        hw_pos = 0;
    ach->cap_buffer_pos = hw_pos;
    return bytes_to_frames(substream->runtime, ach->cap_buffer_pos);
}

static const struct snd_pcm_ops qpcie_alsa_capture_ops = {
    .open        = qpcie_alsa_cap_open,
    .close       = qpcie_alsa_cap_close,
    .hw_params   = qpcie_alsa_hw_params,
    .hw_free     = qpcie_alsa_hw_free,
    .prepare     = qpcie_alsa_cap_prepare,
    .trigger     = qpcie_alsa_cap_trigger,
    .pointer     = qpcie_alsa_cap_pointer,
};

/* ========================================================================= */
/* ALSA Playback Stream Callbacks (H2C Loopback FIFO + HRTimer Pacer)        */
/* ========================================================================= */

static void qpcie_alsa_pump_playback(struct qpcie_alsa_channel *ach)
{
    struct qpcie_dev *qdev = ach->qdev;
    struct snd_pcm_substream *substream;
    struct snd_pcm_runtime *runtime;
    snd_pcm_uframes_t appl_ptr, buf_frames, period_frames;
    snd_pcm_sframes_t avail;
    u32 *buf;
    u32 reg_data;
    unsigned long flags;
    int periods_elapsed = 0;

    spin_lock_irqsave(&ach->slock, flags);
    substream = ach->play_substream;
    if (!substream || !snd_pcm_running(substream)) {
        spin_unlock_irqrestore(&ach->slock, flags);
        return;
    }

    runtime = substream->runtime;
    if (!runtime || !runtime->dma_area || !runtime->control) {
        spin_unlock_irqrestore(&ach->slock, flags);
        return;
    }

    appl_ptr = READ_ONCE(runtime->control->appl_ptr);
    buf_frames = runtime->buffer_size;
    period_frames = runtime->period_size;
    buf = (u32 *)runtime->dma_area;
    reg_data = REG_AUDIO_H2C_DATA_CH(ach->channel_id);

    avail = (snd_pcm_sframes_t)(appl_ptr - ach->play_hw_ptr);
    if (avail <= 0) {
        spin_unlock_irqrestore(&ach->slock, flags);
        return;
    }
    if (avail > (snd_pcm_sframes_t)buf_frames) {
        avail = buf_frames;
    }

    while (avail > 0) {
        u32 st = ioread32(qdev->bar0_mmio + REG_AUDIO_H2C_STATUS);
        if (H2C_FIFO_FULL_CH(st, ach->channel_id))
            break;

        u32 cur_frame_idx = (u32)(ach->play_hw_ptr % buf_frames);
        u32 ch;
        for (ch = 0; ch < runtime->channels; ch++) {
            u32 sample = buf[cur_frame_idx * runtime->channels + ch];
            iowrite32(sample, qdev->bar0_mmio + reg_data);
        }

        ach->play_hw_ptr++;
        ach->play_period_accum++;
        avail--;

        while (ach->play_period_accum >= period_frames) {
            ach->play_period_accum -= period_frames;
            periods_elapsed++;
        }
    }

    spin_unlock_irqrestore(&ach->slock, flags);

    while (periods_elapsed-- > 0) {
        snd_pcm_period_elapsed(substream);
    }
}

static enum hrtimer_restart qpcie_alsa_play_timer_callback(struct hrtimer *timer)
{
    struct qpcie_alsa_channel *ach = container_of(timer, struct qpcie_alsa_channel, play_timer);
    bool active;
    unsigned long flags;

    spin_lock_irqsave(&ach->slock, flags);
    active = ach->play_timer_active;
    spin_unlock_irqrestore(&ach->slock, flags);

    if (!active)
        return HRTIMER_NORESTART;

    qpcie_alsa_pump_playback(ach);

    spin_lock_irqsave(&ach->slock, flags);
    active = ach->play_timer_active;
    spin_unlock_irqrestore(&ach->slock, flags);

    if (!active)
        return HRTIMER_NORESTART;

    hrtimer_forward_now(timer, ms_to_ktime(1));
    return HRTIMER_RESTART;
}

static int qpcie_alsa_play_open(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct snd_pcm_runtime *runtime = substream->runtime;

    ach->play_substream = substream;
    runtime->hw = qpcie_alsa_hardware;
    return 0;
}

static int qpcie_alsa_play_close(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    unsigned long flags;

    spin_lock_irqsave(&ach->slock, flags);
    ach->play_timer_active = false;
    spin_unlock_irqrestore(&ach->slock, flags);

    hrtimer_cancel(&ach->play_timer);
    ach->play_substream = NULL;
    return 0;
}

static int qpcie_alsa_play_prepare(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    unsigned long flags;

    spin_lock_irqsave(&ach->slock, flags);
    ach->play_timer_active = false;
    ach->play_hw_ptr = 0;
    ach->play_period_accum = 0;
    ach->play_buffer_pos = 0;
    spin_unlock_irqrestore(&ach->slock, flags);

    hrtimer_cancel(&ach->play_timer);

    // Reset/flush H2C FIFO on prepare
    if (ach->channel_id >= 1 && ach->channel_id <= 3) {
        u32 ctrl = ioread32(qdev->bar0_mmio + REG_AUDIO_LOOPBACK_CTRL);
        iowrite32(ctrl | BIT(7 + ach->channel_id), qdev->bar0_mmio + REG_AUDIO_LOOPBACK_CTRL);
        iowrite32(ctrl & ~BIT(7 + ach->channel_id), qdev->bar0_mmio + REG_AUDIO_LOOPBACK_CTRL);
    }
    dev_info(&qdev->pdev->dev, "[ALSA Ch%d Playback Prepare]\n", ach->channel_id);
    return 0;
}

static int qpcie_alsa_play_trigger(struct snd_pcm_substream *substream, int cmd)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    unsigned long flags;

    switch (cmd) {
    case SNDRV_PCM_TRIGGER_START:
    case SNDRV_PCM_TRIGGER_RESUME:
        spin_lock_irqsave(&ach->slock, flags);
        ach->play_timer_active = true;
        spin_unlock_irqrestore(&ach->slock, flags);

        hrtimer_start(&ach->play_timer, ms_to_ktime(1), HRTIMER_MODE_REL);
        qpcie_alsa_pump_playback(ach);
        dev_info(&qdev->pdev->dev, "[ALSA Ch%d Playback] Started\n", ach->channel_id);
        break;

    case SNDRV_PCM_TRIGGER_STOP:
    case SNDRV_PCM_TRIGGER_SUSPEND:
        spin_lock_irqsave(&ach->slock, flags);
        ach->play_timer_active = false;
        spin_unlock_irqrestore(&ach->slock, flags);

        hrtimer_cancel(&ach->play_timer);
        dev_info(&qdev->pdev->dev, "[ALSA Ch%d Playback] Stopped\n", ach->channel_id);
        break;

    default:
        return -EINVAL;
    }
    return 0;
}

static snd_pcm_uframes_t qpcie_alsa_play_pointer(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct snd_pcm_runtime *runtime = substream->runtime;
    snd_pcm_uframes_t pos;
    unsigned long flags;

    spin_lock_irqsave(&ach->slock, flags);
    pos = ach->play_hw_ptr % runtime->buffer_size;
    spin_unlock_irqrestore(&ach->slock, flags);

    return pos;
}

static int qpcie_alsa_play_ack(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);

    if (ach->channel_id < 1 || ach->channel_id > 3)
        return 0;

    qpcie_alsa_pump_playback(ach);
    return 0;
}

static const struct snd_pcm_ops qpcie_alsa_playback_ops = {
    .open        = qpcie_alsa_play_open,
    .close       = qpcie_alsa_play_close,
    .hw_params   = qpcie_alsa_hw_params,
    .hw_free     = qpcie_alsa_hw_free,
    .prepare     = qpcie_alsa_play_prepare,
    .trigger     = qpcie_alsa_play_trigger,
    .pointer     = qpcie_alsa_play_pointer,
    .ack         = qpcie_alsa_play_ack,
};


/* ========================================================================= */
/* ALSA Control Framework (BAR1 Audio Pattern Gen Controls for Ch0)         */
/* ========================================================================= */

static int qpcie_alsa_pattern_info(struct snd_kcontrol *kcontrol, struct snd_ctl_elem_info *uinfo)
{
    static const char * const texts[] = {
        "L-Sine / R-Saw (Split)",
        "1kHz Sine (Stereo)",
        "Sawtooth (Stereo)",
        "440Hz Tone (Stereo)",
        "Mute / Silence",
        NULL
    };
    return snd_ctl_enum_info(uinfo, 1, 5, texts);
}

static int qpcie_alsa_pattern_get(struct snd_kcontrol *kcontrol, struct snd_ctl_elem_value *ucontrol)
{
    struct qpcie_alsa_channel *ach = snd_kcontrol_chip(kcontrol);
    struct qpcie_dev *qdev = ach->qdev;
    u32 ctrl_val;

    if (qdev && qdev->bar1_mmio) {
        ctrl_val = ioread32(qdev->bar1_mmio + BAR1_OFFSET_AUDIO_GEN + 0x00);
        ach->pattern_id = (ctrl_val >> 1) & 0x07;
    }
    ucontrol->value.enumerated.item[0] = ach->pattern_id & 0x07;
    return 0;
}

static int qpcie_alsa_pattern_put(struct snd_kcontrol *kcontrol, struct snd_ctl_elem_value *ucontrol)
{
    struct qpcie_alsa_channel *ach = snd_kcontrol_chip(kcontrol);
    struct qpcie_dev *qdev = ach->qdev;
    u32 pattern_id = ucontrol->value.enumerated.item[0];

    if (pattern_id > 4) return -EINVAL;
    ach->pattern_id = pattern_id;

    if (qdev && qdev->bar1_mmio) {
        u32 ctrl_val = ioread32(qdev->bar1_mmio + BAR1_OFFSET_AUDIO_GEN + 0x00);
        ctrl_val = (ctrl_val & ~0x0E) | ((pattern_id & 0x07) << 1) | 0x01;
        iowrite32(ctrl_val, qdev->bar1_mmio + BAR1_OFFSET_AUDIO_GEN + 0x00);
        dev_info(&qdev->pdev->dev, "ALSA Mixer: Set Audio Pattern ID to %u\n", pattern_id);
    }
    return 1;
}

static int qpcie_alsa_volume_info(struct snd_kcontrol *kcontrol, struct snd_ctl_elem_info *uinfo)
{
    uinfo->type = SNDRV_CTL_ELEM_TYPE_INTEGER;
    uinfo->count = 1;
    uinfo->value.integer.min = 0;
    uinfo->value.integer.max = 255;
    return 0;
}

static int qpcie_alsa_volume_get(struct snd_kcontrol *kcontrol, struct snd_ctl_elem_value *ucontrol)
{
    struct qpcie_alsa_channel *ach = snd_kcontrol_chip(kcontrol);
    struct qpcie_dev *qdev = ach->qdev;

    if (qdev && qdev->bar1_mmio) {
        ach->volume = ioread32(qdev->bar1_mmio + BAR1_OFFSET_AUDIO_GEN + 0x08);
    }
    ucontrol->value.integer.value[0] = ach->volume;
    return 0;
}

static int qpcie_alsa_volume_put(struct snd_kcontrol *kcontrol, struct snd_ctl_elem_value *ucontrol)
{
    struct qpcie_alsa_channel *ach = snd_kcontrol_chip(kcontrol);
    struct qpcie_dev *qdev = ach->qdev;
    u32 volume = ucontrol->value.integer.value[0];

    if (volume > 255) volume = 255;
    ach->volume = volume;

    if (qdev && qdev->bar1_mmio) {
        iowrite32(volume, qdev->bar1_mmio + BAR1_OFFSET_AUDIO_GEN + 0x08);
        dev_info(&qdev->pdev->dev, "ALSA Mixer: Set Audio Volume %u\n", volume);
    }
    return 1;
}

static const struct snd_kcontrol_new qpcie_alsa_controls[] = {
    {
        .iface = SNDRV_CTL_ELEM_IFACE_MIXER,
        .name  = "Audio Pattern",
        .info  = qpcie_alsa_pattern_info,
        .get   = qpcie_alsa_pattern_get,
        .put   = qpcie_alsa_pattern_put,
    },
    {
        .iface = SNDRV_CTL_ELEM_IFACE_MIXER,
        .name  = "PCM Volume",
        .info  = qpcie_alsa_volume_info,
        .get   = qpcie_alsa_volume_get,
        .put   = qpcie_alsa_volume_put,
    },
};

/* ========================================================================= */
/* ALSA Initialization & Cleanup                                             */
/* ========================================================================= */

int qpcie_alsa_init(struct qpcie_dev *qdev)
{
    int i, ret;

    dev_info(&qdev->pdev->dev, "Starting Multi-Channel ALSA Audio Subsystem Init (%d Channels)...\n",
             NUM_AUDIO_CHANNELS);

    for (i = 0; i < NUM_AUDIO_CHANNELS; i++) {
        struct qpcie_alsa_channel *ach = &qdev->alsa_ch[i];
        struct snd_card *card;
        char card_id[32];
        int k;

        ach->qdev       = qdev;
        ach->channel_id = i;
        spin_lock_init(&ach->slock);

        if (i > 0) {
            qpcie_hrtimer_init(&ach->play_timer, qpcie_alsa_play_timer_callback, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
            ach->play_timer_active = false;
            ach->play_hw_ptr = 0;
            ach->play_period_accum = 0;
        }

        snprintf(card_id, sizeof(card_id), "QPCIe-Audio-%d", i);
        ret = snd_card_new(&qdev->pdev->dev, -1, card_id, THIS_MODULE, 0, &card);
        if (ret) {
            dev_err(&qdev->pdev->dev, "Audio Ch %d: snd_card_new failed: %d\n", i, ret);
            return ret;
        }

        ach->card = card;
        strscpy(card->driver, "qpcie-alsa", sizeof(card->driver));

        if (i == 0) {
            strscpy(card->shortname, "QPCIe AES3 Audio", sizeof(card->shortname));
            snprintf(card->longname, sizeof(card->longname), "QPCIe Audio Ch0 (Pattern Gen Source)");

            // Card 0: Device 0 = Capture Only (Pattern Gen Source) -> /dev/snd/pcmC<X>D0c
            ret = snd_pcm_new(card, "QPCIe AES3 Capture", 0, 0, 1, &ach->pcm_cap);
            if (ret) {
                dev_err(&qdev->pdev->dev, "Audio Ch %d: snd_pcm_new capture failed: %d\n", i, ret);
                goto free_card;
            }
            ach->pcm_cap->private_data = ach;
            strscpy(ach->pcm_cap->name, "QPCIe AES3 Subframe PCM", sizeof(ach->pcm_cap->name));
            snd_pcm_set_ops(ach->pcm_cap, SNDRV_PCM_STREAM_CAPTURE, &qpcie_alsa_capture_ops);
            snd_pcm_set_managed_buffer_all(ach->pcm_cap, SNDRV_DMA_TYPE_DEV, &qdev->pdev->dev, 64 * 1024, 128 * 1024);

            // Register Mixer Controls for Ch0 Pattern Generator
            for (k = 0; k < ARRAY_SIZE(qpcie_alsa_controls); k++) {
                ret = snd_ctl_add(card, snd_ctl_new1(&qpcie_alsa_controls[k], ach));
                if (ret < 0) {
                    dev_err(&qdev->pdev->dev, "Audio Ch %d: snd_ctl_add failed: %d\n", i, ret);
                    goto free_card;
                }
            }
        } else {
            snprintf(card->shortname, sizeof(card->shortname), "QPCIe Audio Ch%d", i);
            snprintf(card->longname, sizeof(card->longname), "QPCIe Audio Loopback Channel %d", i);

            // Cards 1..3: Device 0 = Output (Playback) -> /dev/snd/pcmC<X>D0p
            ret = snd_pcm_new(card, "QPCIe Audio Playback", 0, 1, 0, &ach->pcm_play);
            if (ret) {
                dev_err(&qdev->pdev->dev, "Audio Ch %d: snd_pcm_new playback failed: %d\n", i, ret);
                goto free_card;
            }
            ach->pcm_play->private_data = ach;
            strscpy(ach->pcm_play->name, "QPCIe Audio Playback PCM", sizeof(ach->pcm_play->name));
            snd_pcm_set_ops(ach->pcm_play, SNDRV_PCM_STREAM_PLAYBACK, &qpcie_alsa_playback_ops);
            snd_pcm_set_managed_buffer_all(ach->pcm_play, SNDRV_DMA_TYPE_DEV, &qdev->pdev->dev, 64 * 1024, 128 * 1024);

            // Cards 1..3: Device 1 = Input (Capture) -> /dev/snd/pcmC<X>D1c
            ret = snd_pcm_new(card, "QPCIe Audio Capture", 1, 0, 1, &ach->pcm_cap);
            if (ret) {
                dev_err(&qdev->pdev->dev, "Audio Ch %d: snd_pcm_new capture failed: %d\n", i, ret);
                goto free_card;
            }
            ach->pcm_cap->private_data = ach;
            strscpy(ach->pcm_cap->name, "QPCIe Audio Capture PCM", sizeof(ach->pcm_cap->name));
            snd_pcm_set_ops(ach->pcm_cap, SNDRV_PCM_STREAM_CAPTURE, &qpcie_alsa_capture_ops);
            snd_pcm_set_managed_buffer_all(ach->pcm_cap, SNDRV_DMA_TYPE_DEV, &qdev->pdev->dev, 64 * 1024, 128 * 1024);
        }

        ret = snd_card_register(card);
        if (ret) {
            dev_err(&qdev->pdev->dev, "Audio Ch %d: snd_card_register failed: %d\n", i, ret);
            goto free_card;
        }

        dev_info(&qdev->pdev->dev, " -> Audio Channel %d registered as ALSA Card #%d ('%s')\n",
                 i, card->number, card->shortname);
        continue;

free_card:
        snd_card_free(card);
        return ret;
    }
    dev_info(&qdev->pdev->dev, "🎉 [ALSA INIT COMPLETE] All %d ALSA Audio Cards Initialized Successfully!\n",
             NUM_AUDIO_CHANNELS);
    return 0;
}

void qpcie_alsa_remove(struct qpcie_dev *qdev)
{
    int i;
    for (i = 0; i < NUM_AUDIO_CHANNELS; i++) {
        struct qpcie_alsa_channel *ach = &qdev->alsa_ch[i];
        if (i > 0) {
            ach->play_timer_active = false;
            hrtimer_cancel(&ach->play_timer);
        }
        if (ach->card)
            snd_card_free(ach->card);
    }
}

void qpcie_alsa_irq_handler(struct qpcie_dev *qdev, u32 status)
{
    int i;
    for (i = 0; i < NUM_AUDIO_CHANNELS; i++) {
        struct qpcie_alsa_channel *ach = &qdev->alsa_ch[i];

        if (status & IRQ_STATUS_AUDIO_CH(i)) {
            // Capture period done
            if (ach->cap_substream && snd_pcm_running(ach->cap_substream)) {
                u32 hw_pos = ioread32(qdev->bar0_mmio + REG_AUDIO_DMA_PTR_CH(i));
                size_t buf_bytes = snd_pcm_lib_buffer_bytes(ach->cap_substream);
                if (hw_pos >= buf_bytes)
                    hw_pos = 0;
                ach->cap_buffer_pos = hw_pos;
                snd_pcm_period_elapsed(ach->cap_substream);
            }
        }
    }
}

