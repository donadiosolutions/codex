#!/usr/bin/env python3
"""Measure the entire container, including detached sccache compiler processes."""

import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path('/bench')
CGROUP = Path('/sys/fs/cgroup')
INTERVAL = 0.25


def cpu():
    return dict((key, int(value)) for key, value in
                (line.split() for line in (CGROUP / 'cpu.stat').read_text().splitlines()))


def rss():
    total = 0
    for pid in (CGROUP / 'cgroup.procs').read_text().split():
        try:
            for line in Path('/proc', pid, 'status').read_text().splitlines():
                if line.startswith('VmRSS:'):
                    total += int(line.split()[1]) * 1024
                    break
        except (FileNotFoundError, ProcessLookupError):
            pass
    return total


def cache_stats(filename):
    output = subprocess.check_output(
        ['/usr/bin/sccache', '--show-stats', '--stats-format', 'json'], text=True)
    (ROOT / filename).write_text(output)
    return json.loads(output)


def main():
    command = ['/usr/bin/cargo', 'build', '-Zbuild-std=std,panic_abort',
               '--locked', '--release', '--target', 'x86_64-unknown-linux-gnu',
               '--jobs', '16', '--timings', '-v', '-p', 'codex-cli', '--bin', 'codex',
               '-p', 'codex-code-mode-host', '--bin', 'codex-code-mode-host']
    metadata = {
        'command': command, 'rustflags': os.environ['RUSTFLAGS'],
        'rustc': subprocess.check_output(['/usr/bin/rustc', '-Vv'], text=True),
        'glibc': subprocess.check_output(['getconf', 'GNU_LIBC_VERSION'], text=True),
        'source_commit': os.environ['STABLE_GIT_COMMIT'],
        'sccache_dir': os.environ['SCCACHE_DIR'],
        'cargo_home': os.environ['CARGO_HOME'],
        'cargo_target_dir': os.environ['CARGO_TARGET_DIR'],
        'phase': os.environ['BENCHMARK_PHASE'],
        'rss_sample_interval_seconds': INTERVAL,
    }
    (ROOT / 'build-environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
    subprocess.run(['/usr/bin/sccache', '--zero-stats'], check=True)
    cache_stats('sccache-before.json')
    start_cpu = cpu()
    start = time.monotonic()
    peak_rss = rss()
    peak_memory = int((CGROUP / 'memory.current').read_text())
    last_update = start
    with (ROOT / 'build.log').open('w') as log:
        process = subprocess.Popen(
            ['/usr/bin/time', '-v', '-o', str(ROOT / 'gnu-time.txt'),
             'timeout', '--signal=TERM', '--kill-after=30s', '3h', *command],
            stdout=log, stderr=subprocess.STDOUT)
        while process.poll() is None:
            peak_rss = max(peak_rss, rss())
            peak_memory = max(peak_memory, int((CGROUP / 'memory.current').read_text()))
            now = time.monotonic()
            if now - last_update >= 45:
                print(f'Build running: {now-start:.0f}s elapsed; peak aggregate RSS '
                      f'{peak_rss / 1024**3:.2f} GiB', flush=True)
                last_update = now
            time.sleep(INTERVAL)
        end = time.monotonic()
        end_cpu = cpu()
        status = process.wait()
    after_stats = cache_stats('sccache-after.json')
    gnu_time = (ROOT / 'gnu-time.txt').read_text()
    gnu_peak_kib = next((int(line.split(':', 1)[1].strip())
                         for line in gnu_time.splitlines()
                         if 'Maximum resident set size (kbytes)' in line), None)
    result = {
        'phase': os.environ['BENCHMARK_PHASE'], 'exit_code': status,
        'wall_seconds': end - start,
        'cpu_user_seconds': (end_cpu['user_usec'] - start_cpu['user_usec']) / 1e6,
        'cpu_system_seconds': (end_cpu['system_usec'] - start_cpu['system_usec']) / 1e6,
        'cpu_total_seconds': (end_cpu['usage_usec'] - start_cpu['usage_usec']) / 1e6,
        'peak_aggregate_rss_bytes_sampled': peak_rss,
        'peak_cgroup_memory_bytes_sampled': peak_memory,
        'gnu_time_max_rss_bytes': None if gnu_peak_kib is None else gnu_peak_kib * 1024,
        'cgroup_memory_peak_bytes_since_container_start': int((CGROUP / 'memory.peak').read_text()),
        'cpu_counters_before': start_cpu, 'cpu_counters_after': end_cpu,
        'rss_sample_interval_seconds': INTERVAL,
        'sccache_stats': after_stats,
        'measurement': 'Container cgroup CPU delta includes sccache server and compilers; '
                       'RSS is the maximum sampled sum of resident process memory. '
                       'GNU time max RSS measures the largest waited-for process, not the aggregate.',
    }
    (ROOT / 'metrics.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)
    print(subprocess.check_output(['/usr/bin/sccache', '--show-stats'], text=True), flush=True)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
