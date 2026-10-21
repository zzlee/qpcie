#!/usr/bin/env python3
import sys
import subprocess
import math
import gzip
import os

def exec_card(cmd):
    p = subprocess.run(['ssh', 'rd@sc7f0-test.local', f'sudo /home/rd/sc7f0ctl exec {cmd!r}'],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f"ERR (exit {p.returncode}): {p.stderr}", file=sys.stderr)
    return p.stdout

def push_file(local_path, remote_path):
    with open(local_path, 'rb') as f:
        data = f.read()
    gz = gzip.compress(data, compresslevel=9)
    b32 = subprocess.run(['base32'], input=gz, capture_output=True).stdout.decode('ascii').strip().replace('\n', '')
    
    b32_remote = remote_path + '.b32'
    exec_card(f'rm -f {b32_remote} {remote_path}')
    chunk_size = 1500
    n_chunks = math.ceil(len(b32) / chunk_size)
    print(f'Sending {os.path.basename(local_path)} ({len(b32)} b32 chars in {n_chunks} chunks)...')
    for i in range(n_chunks):
        chunk = b32[i*chunk_size : (i+1)*chunk_size]
        exec_card(f'printf "{chunk}" >> {b32_remote}')
    exec_card(f'base32 -d {b32_remote} | gunzip > {remote_path} && chmod +x {remote_path} && rm -f {b32_remote}')

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: card_push_run.py <local_binary> [remote_args...]")
        print("       card_push_run.py --exec '<remote_cmd>'")
        sys.exit(1)
    
    if sys.argv[1] == '--exec':
        print(exec_card(sys.argv[2]))
    else:
        local_bin = sys.argv[1]
        remote_bin = '/tmp/' + os.path.basename(local_bin)
        push_file(local_bin, remote_bin)
        args = ' '.join(sys.argv[2:])
        print(exec_card(f'{remote_bin} {args}'))
