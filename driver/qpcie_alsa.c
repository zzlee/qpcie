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
    return snd_pcm_lib_malloc_pages(substream, params_buffer_bytes(hw_params));
}

static int qpcie_alsa_hw_free(struct snd_pcm_substream *substream)
{
    return snd_pcm_lib_free_pages(substream);
}

static int qpcie_alsa_prepare(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    ach->buffer_pos = 0;
    ach->period_pos = 0;
    return 0;
}

static int qpcie_alsa_trigger(struct snd_pcm_substream *substream, int cmd)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
    struct qpcie_dev *qdev = ach->qdev;

    switch (cmd) {
    case SNDRV_PCM_TRIGGER_START:
        iowrite32(0x02, qdev->bar0_mmio + REG_DMA_CTRL); /* Start Audio DMA */
        break;
    case SNDRV_PCM_TRIGGER_STOP:
        iowrite32(0x00, qdev->bar0_mmio + REG_DMA_CTRL); /* Stop DMA */
        break;
    default:
        return -EINVAL;
    }
    return 0;
}

static snd_pcm_uframes_t qpcie_alsa_pointer(struct snd_pcm_substream *substream)
{
    struct qpcie_alsa_channel *ach = snd_pcm_substream_chip(substream);
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

int qpcie_alsa_init(struct qpcie_dev *qdev)
{
    int i, ret;

    for (i = 0; i < NUM_AUDIO_CHANNELS; i++) {
        struct qpcie_alsa_channel *ach = &qdev->alsa_ch[i];
        struct snd_card *card;
        struct snd_pcm *pcm;

        ach->qdev       = qdev;
        ach->channel_id = i;
        spin_lock_init(&ach->slock);

        ret = snd_card_new(&qdev->pdev->dev, -1, "QPCIe-AES3", THIS_MODULE, 0, &card);
        if (ret) return ret;

        ach->card = card;
        strscpy(card->driver, "qpcie-alsa", sizeof(card->driver));
        strscpy(card->shortname, "QPCIe AES3 Audio", sizeof(card->shortname));
        snprintf(card->longname, sizeof(card->longname), "QPCIe Multi-Channel AES3 Audio Channel %d", i);

        ret = snd_pcm_new(card, "QPCIe AES3 PCM", 0, 1, 1, &pcm);
        if (ret) goto free_card;

        ach->pcm = pcm;
        pcm->private_data = ach;
        strscpy(pcm->name, "QPCIe AES3 Subframe PCM", sizeof(pcm->name));

        snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_CAPTURE, &qpcie_alsa_pcm_ops);
        snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_PLAYBACK, &qpcie_alsa_pcm_ops);
        snd_pcm_set_managed_buffer_all(pcm, SNDRV_DMA_TYPE_DEV, &qdev->pdev->dev, 64 * 1024, 128 * 1024);

        ret = snd_card_register(card);
        if (ret) goto free_card;

        continue;

free_card:
        snd_card_free(card);
        return ret;
    }
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
            struct snd_pcm_runtime *runtime = ach->substream->runtime;
            unsigned long flags;

            spin_lock_irqsave(&ach->slock, flags);
            ach->buffer_pos += runtime->period_size * 4;
            if (ach->buffer_pos >= runtime->buffer_size * 4)
                ach->buffer_pos = 0;
            spin_unlock_irqrestore(&ach->slock, flags);

            snd_pcm_period_elapsed(ach->substream);
        }
    }
}
