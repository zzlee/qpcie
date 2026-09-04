// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Driver: qpcie_alsa.c
 * Description: ALSA Sound Card Driver for Custom PCIe AES3 Audio Streaming.
 */

#include "qpcie_driver.h"

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

static int qpcie_alsa_open(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct snd_pcm_runtime *runtime = substream->runtime;

    ach->substream = substream;
    runtime->hw = qpcie_alsa_hardware;
    return 0;
}

static int qpcie_alsa_close(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    ach->substream = NULL;
    return 0;
}

static int qpcie_alsa_hw_params(struct snd_pcm_substream *substream, struct snd_pcm_hw_params *hw_params)
{
    /* Managed buffer allocated automatically by ALSA core via snd_pcm_set_managed_buffer_all */
    return 0;
}

static int qpcie_alsa_hw_free(struct snd_pcm_substream *substream)
{
    /* Managed buffer freed automatically by ALSA core */
    return 0;
}

static int qpcie_alsa_prepare(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    dma_addr_t dma_addr = substream->runtime->dma_addr;
    size_t buffer_bytes = snd_pcm_lib_buffer_bytes(substream);
    size_t period_bytes = snd_pcm_lib_period_bytes(substream);

    ach->buffer_pos = 0;
    ach->period_pos = 0;

    if (ach->channel_id == 0) {
        iowrite32(lower_32_bits(dma_addr), qdev->bar0_mmio + REG_AUDIO_DMA_ADDR_L);
        iowrite32(upper_32_bits(dma_addr), qdev->bar0_mmio + REG_AUDIO_DMA_ADDR_H);
        iowrite32(((u32)period_bytes << 16) | ((u32)buffer_bytes & 0xFFFF),
                  qdev->bar0_mmio + REG_AUDIO_DMA_CFG);

        dev_info(&qdev->pdev->dev,
                 "[ALSA Ch%d Prepare] DMA=0x%llX, buffer=%zu bytes, period=%zu bytes\n",
                 ach->channel_id, (u64)dma_addr, buffer_bytes, period_bytes);
    }
    return 0;
}

static int qpcie_alsa_trigger(struct snd_pcm_substream *substream, int cmd)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    u32 ctrl;

    switch (cmd) {
    case SNDRV_PCM_TRIGGER_START:
        if (ach->channel_id == 0) {
            ctrl = ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
            iowrite32(ctrl | DMA_CTRL_AUDIO_RUN, qdev->bar0_mmio + REG_DMA_CTRL);
            dev_info(&qdev->pdev->dev, "[ALSA Ch%d] Audio DMA Stream Started\n", ach->channel_id);
        }
        break;
    case SNDRV_PCM_TRIGGER_STOP:
        if (ach->channel_id == 0) {
            ctrl = ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
            iowrite32(ctrl & ~DMA_CTRL_AUDIO_RUN, qdev->bar0_mmio + REG_DMA_CTRL);
            dev_info(&qdev->pdev->dev, "[ALSA Ch%d] Audio DMA Stream Stopped\n", ach->channel_id);
        }
        break;
    default:
        return -EINVAL;
    }
    return 0;
}

static snd_pcm_uframes_t qpcie_alsa_pointer(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;
    u32 hw_pos;
    size_t buf_bytes = snd_pcm_lib_buffer_bytes(substream);

    if (ach->channel_id == 0) {
        hw_pos = ioread32(qdev->bar0_mmio + REG_AUDIO_DMA_PTR);
        if (hw_pos >= buf_bytes)
            hw_pos = 0;
        ach->buffer_pos = hw_pos;
    }
    return bytes_to_frames(substream->runtime, ach->buffer_pos);
}

static const struct snd_pcm_ops qpcie_alsa_pcm_ops = {
    .open        = qpcie_alsa_open,
    .close       = qpcie_alsa_close,
    .hw_params   = qpcie_alsa_hw_params,
    .hw_free     = qpcie_alsa_hw_free,
    .prepare     = qpcie_alsa_prepare,
    .trigger     = qpcie_alsa_trigger,
    .pointer     = qpcie_alsa_pointer,
};

/* ALSA Control Framework Integration ('Audio Pattern' and 'PCM Volume') */

static int qpcie_alsa_pattern_info(struct snd_kcontrol *kcontrol, struct snd_ctl_elem_info *uinfo)
{
    static const char * const texts[] = {
        "1kHz Sine Wave",
        "Sawtooth Wave",
        "440Hz Tone",
        "Mute / Silence",
        NULL
    };
    return snd_ctl_enum_info(uinfo, 1, 4, texts);
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

    if (pattern_id > 3) return -EINVAL;
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

int qpcie_alsa_init(struct qpcie_dev *qdev)
{
    int i, ret;

    dev_info(&qdev->pdev->dev, "[DEBUG STEP 3.1] Starting ALSA Audio Subsystem Init...\n");

    for (i = 0; i < NUM_AUDIO_CHANNELS; i++) {
        struct qpcie_alsa_channel *ach = &qdev->alsa_ch[i];
        struct snd_card *card;
        struct snd_pcm *pcm;
        int k;

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 3.2] Initializing Audio Channel %d...\n", i);
        ach->qdev       = qdev;
        ach->channel_id = i;
        spin_lock_init(&ach->slock);

        ret = snd_card_new(&qdev->pdev->dev, -1, "QPCIe-AES3", THIS_MODULE, 0, &card);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Audio Ch %d: snd_card_new failed: %d\n", i, ret);
            return ret;
        }

        ach->card = card;
        strscpy(card->driver, "qpcie-alsa", sizeof(card->driver));
        strscpy(card->shortname, "QPCIe AES3 Audio", sizeof(card->shortname));
        snprintf(card->longname, sizeof(card->longname), "QPCIe Multi-Channel AES3 Audio Channel %d", i);

        ret = snd_pcm_new(card, "QPCIe AES3 PCM", 0, 1, 1, &pcm);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Audio Ch %d: snd_pcm_new failed: %d\n", i, ret);
            goto free_card;
        }

        ach->pcm = pcm;
        pcm->private_data = ach;
        strscpy(pcm->name, "QPCIe AES3 Subframe PCM", sizeof(pcm->name));

        snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_CAPTURE, &qpcie_alsa_pcm_ops);
        snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_PLAYBACK, &qpcie_alsa_pcm_ops);
        snd_pcm_set_managed_buffer_all(pcm, SNDRV_DMA_TYPE_DEV, &qdev->pdev->dev, 64 * 1024, 128 * 1024);

        /* Register ALSA Mixer Controls */
        for (k = 0; k < ARRAY_SIZE(qpcie_alsa_controls); k++) {
            ret = snd_ctl_add(card, snd_ctl_new1(&qpcie_alsa_controls[k], ach));
            if (ret < 0) {
                dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Audio Ch %d: snd_ctl_add failed: %d\n", i, ret);
                goto free_card;
            }
        }

        ret = snd_card_register(card);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Audio Ch %d: snd_card_register failed: %d\n", i, ret);
            goto free_card;
        }

        dev_info(&qdev->pdev->dev, " -> Audio Channel %d registered as ALSA Card #%d\n", i, card->number);
        continue;

free_card:
        snd_card_free(card);
        return ret;
    }
    dev_info(&qdev->pdev->dev, "🎉 [DEBUG STEP 3 COMPLETE] All ALSA Audio Cards Initialized Successfully!\n");
    return 0;
}

void qpcie_alsa_remove(struct qpcie_dev *qdev)
{
    int i;
    for (i = 0; i < NUM_AUDIO_CHANNELS; i++) {
        if (qdev->alsa_ch[i].card)
            snd_card_free(qdev->alsa_ch[i].card);
    }
}

void qpcie_alsa_irq_handler(struct qpcie_dev *qdev)
{
    int i;
    for (i = 0; i < NUM_AUDIO_CHANNELS; i++) {
        struct qpcie_alsa_channel *ach = &qdev->alsa_ch[i];
        if (ach->substream && snd_pcm_running(ach->substream)) {
            if (ach->channel_id == 0) {
                u32 hw_pos = ioread32(qdev->bar0_mmio + REG_AUDIO_DMA_PTR);
                size_t buf_bytes = snd_pcm_lib_buffer_bytes(ach->substream);
                if (hw_pos >= buf_bytes)
                    hw_pos = 0;
                ach->buffer_pos = hw_pos;
            }
            snd_pcm_period_elapsed(ach->substream);
        }
    }
}
