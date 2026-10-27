#!/usr/bin/env python3
"""Real HDMI NV12 + ALSA PCM in ONE GStreamer pipeline on the x86 desktop.

Requires the AUD1 FPGA ABI and matching driver/PS daemon. ALSA device 0 is
raw TPG diagnostics, NOT PCM audio; use device 1. No video conversion/scaling.
This tool counts actual buffers/rendered frames and fails on missing/silent
HDMI audio unless --allow-silence is explicitly requested. Never falls back
on TPG, USB microphone, audiotestsrc or fakesink.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time

from sc7f0_hdmi_preview import locked_mode


def pipeline_description(video, audio, width, height, audio_output=None, audio_dump=None):
    q = json.dumps
    result = (
        f'v4l2src name=hdmi_video device={q(video)} io-mode=mmap '
        'extra-controls="c,qpcie_video_input_source=2,qpcie_frame_pacer_enable=0" '
        f'! video/x-raw,format=NV12,width={width},height={height},framerate=60/1 '
        '! queue max-size-buffers=4 max-size-bytes=0 max-size-time=0 '
        '! fpsdisplaysink name=video_stats text-overlay=false sync=true '
        'video-sink="waylandsink name=desktop_video fullscreen=true sync=true" '
        'alsasrc name=hdmi_audio provide-clock=false use-driver-timestamps=false slave-method=none '
        f'device={q(audio)} buffer-time=120000 latency-time=10000 '
        '! audio/x-raw,format=S32LE,rate=48000,channels=2,layout=interleaved '
        '! identity name=audio_stats ! tee name=audio_tee '
        'audio_tee. ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=200000000 '
        '! audioconvert ! audioresample '
        '! pulsesink name=desktop_audio provide-clock=false slave-method=skew '
        'sync=true volume=0.25 buffer-time=80000 latency-time=10000 '
    )
    if audio_output:
        result += f'device={q(audio_output)} '
    if audio_dump:
        result += (f'audio_tee. ! queue ! wavenc ! filesink location={q(audio_dump)} '
                   'sync=false async=false ')
    return result


def audio_pts_delta(previous_pts, previous_frames, pts):
    """Signed gap/overlap against the previous buffer's exact PCM duration."""
    return pts - previous_pts - previous_frames * 1000000000 // 48000


def transport_ok(state):
    """Reject stalled/short-lived branches, even when caps and EOS look valid.

    A pass is transport evidence only, NOT audible playback or lip-sync proof.
    Both live sources use the common system clock; retain measured rates.
    """
    return (not state['errors'] and not state['warnings'] and state['eos']
            and not state['pcm_alignment_errors']
            and not state['audio_pts_jumps'] and not state['audio_missing_pts']
            and state['audio_pts_duration_error_ns'] is not None
            and abs(state['audio_pts_duration_error_ns']) <= 41667
            and state['audio_discont_buffers'] <= 1
            and state['video_rendered'] >= 60
            and state['audio_frames'] >= 48000
            and state['video_source_fps'] >= 55
            and state['video_render_fps'] >= 55
            and 45600 <= state['audio_capture_fps'] <= 50400
            and state['dma_drops_before'] is not None
            and state['dma_drops_after'] == state['dma_drops_before'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--video-device', default='/dev/video0')
    p.add_argument('--audio-device', default='hw:CARD=QPCIeAudio0,DEV=1')
    p.add_argument('--audio-output', help='explicit Pulse/PipeWire sink name; default desktop output')
    p.add_argument('--audio-dump', help='also save the captured (pre-volume) PCM as WAV')
    p.add_argument('--seconds', type=int, default=60, help='0 = continuous until SIGINT')
    p.add_argument('--report', help='JSON evidence report')
    p.add_argument('--allow-silence', action='store_true', help='transport-only check, NOT audible-signal acceptance')
    a = p.parse_args()
    if a.seconds < 0 or (a.seconds and a.seconds < 5):
        p.error('--seconds must be 0 or at least 5')
    node = Path(a.video_device).resolve().name
    pci = Path('/sys/class/video4linux') / node / 'device'
    try:
        width, height, _ = locked_mode((pci / 'hdmi_status').read_text())
    except (OSError, ValueError) as e:
        print(f'ERROR: {e}', file=sys.stderr)
        return 1
    os.environ.setdefault('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
    os.environ.setdefault('WAYLAND_DISPLAY', 'wayland-0')
    import gi
    gi.require_version('Gst', '1.0')
    from gi.repository import Gst, GLib
    Gst.init(None)
    description = pipeline_description(a.video_device, a.audio_device, width, height,
                                       a.audio_output, a.audio_dump)
    print(description, flush=True)
    pipeline = Gst.parse_launch(description)
    loop = GLib.MainLoop()
    audio = pipeline.get_by_name('audio_stats')
    video = pipeline.get_by_name('video_stats')
    sink = pipeline.get_by_name('desktop_audio')
    state = {'audio_buffers': 0, 'audio_frames': 0, 'nonzero_audio_buffers': 0,
             'audio_first_pts_ns': None, 'audio_last_pts_ns': None,
             'errors': [], 'warnings': [], 'clocks': [], 'qos_messages': 0,
             'audio_discont_buffers': 0, 'pcm_alignment_errors': 0, 'eos': False,
             'audio_pts_jumps': 0, 'audio_missing_pts': 0,
             'audio_positive_gap_ns': 0, 'audio_overlap_ns': 0}
    start = time.monotonic()
    first_audio = [None]
    previous_audio = [None, 0]
    first_video = [None]
    state['video_buffers'] = 0
    state['audible_verified'] = False
    state['lip_sync_verified'] = False
    ending = [False]

    def read_int(name):
        try:
            return int((pci / name).read_text().strip(), 0)
        except (OSError, ValueError):
            return None
    drops_before = read_int('ch0_drops')

    def probe(pad, info):
        buf = info.get_buffer()
        if buf is not None:
            if first_audio[0] is None:
                first_audio[0] = time.monotonic()
                print('AUDIO_CAPS:', pad.get_current_caps().to_string(), flush=True)
            state['audio_buffers'] += 1
            state['audio_frames'] += buf.get_size() // 8
            raw = buf.extract_dup(0, buf.get_size())
            if any(raw):
                state['nonzero_audio_buffers'] += 1
            # Left-justified 24-bit S32_LE must not contain AES3 preambles.
            state['pcm_alignment_errors'] += sum(byte != 0 for byte in raw[::4])
            if buf.has_flags(Gst.BufferFlags.DISCONT):
                state['audio_discont_buffers'] += 1
            if buf.pts != Gst.CLOCK_TIME_NONE:
                pts = int(buf.pts)
                if previous_audio[0] is not None:
                    delta = audio_pts_delta(previous_audio[0], previous_audio[1], pts)
                    # Permit at most two samples of integer timestamp rounding.
                    if abs(delta) > 41667:
                        state['audio_pts_jumps'] += 1
                        state['audio_positive_gap_ns'] += max(0, delta)
                        state['audio_overlap_ns'] += max(0, -delta)
                previous_audio[:] = [pts, buf.get_size() // 8]
                if state['audio_first_pts_ns'] is None:
                    state['audio_first_pts_ns'] = pts
                state['audio_last_pts_ns'] = pts
            else:
                state['audio_missing_pts'] += 1
        return Gst.PadProbeReturn.OK
    audio.get_static_pad('src').add_probe(Gst.PadProbeType.BUFFER, probe)

    def video_probe(pad, info):
        if info.get_buffer() is not None:
            if first_video[0] is None:
                first_video[0] = time.monotonic()
            state['video_buffers'] += 1
        return Gst.PadProbeReturn.OK
    pipeline.get_by_name('hdmi_video').get_static_pad('src').add_probe(
        Gst.PadProbeType.BUFFER, video_probe)

    def finish():
        loop.quit()
        return False

    def stop():
        if not ending[0]:
            ending[0] = True
            # Sending EOS may wait on a blocked streaming branch. Do not
            # block the GLib loop before its shutdown deadline is installed.
            GLib.timeout_add_seconds(5, finish)
            threading.Thread(target=lambda: pipeline.send_event(Gst.Event.new_eos()),
                             daemon=True).start()
        return False

    def message(bus, msg):
        if msg.type == Gst.MessageType.ERROR:
            error, debug = msg.parse_error()
            state['errors'].append(f'{msg.src.get_name()}: {error}: {debug}')
            print('GST_ERROR:', state['errors'][-1], flush=True)
            loop.quit()
        elif msg.type == Gst.MessageType.WARNING:
            warning, debug = msg.parse_warning()
            state['warnings'].append(f'{warning}: {debug}')
            print('GST_WARNING:', state['warnings'][-1], flush=True)
        elif msg.type == Gst.MessageType.EOS:
            state['eos'] = True
            loop.quit()
        elif msg.type == Gst.MessageType.NEW_CLOCK:
            clock = msg.parse_new_clock()
            state['clocks'].append(clock.get_name())
            print('PIPELINE_CLOCK:', clock.get_name(), flush=True)
        elif msg.type == Gst.MessageType.LATENCY:
            pipeline.recalculate_latency()
        elif msg.type == Gst.MessageType.QOS:
            state['qos_messages'] += 1

    def progress():
        print(json.dumps({'elapsed_s': round(time.monotonic()-start, 2),
                          'video_rendered': video.get_property('frames-rendered'),
                          'video_dropped': video.get_property('frames-dropped'),
                          'audio_frames': state['audio_frames'],
                          'nonzero_audio_buffers': state['nonzero_audio_buffers'],
                          'dma_drops': read_int('ch0_drops')}), flush=True)
        return True
    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect('message', message)
    GLib.timeout_add_seconds(2, progress)
    if a.seconds:
        GLib.timeout_add_seconds(a.seconds, stop)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, stop)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    try:
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            state['errors'].append('set_state PLAYING failed')
        else:
            loop.run()
        state['elapsed_s'] = round(time.monotonic()-start, 3)
        state['video_rendered'] = video.get_property('frames-rendered')
        state['video_dropped'] = video.get_property('frames-dropped')
        state['dma_drops_before'] = drops_before
        state['dma_drops_after'] = read_int('ch0_drops')
        state['audio_output'] = sink.get_property('current-device')
        stats = sink.get_property('stats')
        state['audio_sink_stats'] = stats.to_string() if stats else None
        end = time.monotonic()
        video_seconds = max(0.001, end-first_video[0]) if first_video[0] is not None else 0
        audio_seconds = max(0.001, end-first_audio[0]) if first_audio[0] is not None else 0
        state['video_source_fps'] = state['video_buffers']/video_seconds if video_seconds else 0
        state['video_render_fps'] = state['video_rendered']/video_seconds if video_seconds else 0
        state['audio_capture_fps'] = state['audio_frames']/audio_seconds if audio_seconds else 0
        state['audio_pts_duration_error_ns'] = None
        if state['audio_first_pts_ns'] is not None and state['audio_last_pts_ns'] is not None:
            state['audio_sample_duration_ns'] = state['audio_frames'] * 1000000000 // 48000
            state['audio_pts_span_ns'] = (state['audio_last_pts_ns'] - state['audio_first_pts_ns']
                                         + previous_audio[1] * 1000000000 // 48000)
            state['audio_pts_duration_error_ns'] = (state['audio_pts_span_ns']
                                                   - state['audio_sample_duration_ns'])
        state['transport_pass'] = transport_ok(state)
        state['signal_pass'] = state['transport_pass'] and state['nonzero_audio_buffers'] > 0
        state['pass'] = state['transport_pass'] if a.allow_silence else state['signal_pass']
        state['pipeline'] = description
    finally:
        pipeline.set_state(Gst.State.NULL)
    if a.report:
        Path(a.report).write_text(json.dumps(state, indent=2)+'\n')
    print(json.dumps(state, indent=2), flush=True)
    return 0 if state.get('pass') else 1


if __name__ == '__main__':
    sys.exit(main())
