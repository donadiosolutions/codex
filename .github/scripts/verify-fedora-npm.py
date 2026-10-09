#!/usr/bin/env python3
"""Verify the actual Fedora npm payload and its relocated voice runtime."""
import hashlib
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import time

root, version, commit, bwrap_digest = Path(sys.argv[1]), *sys.argv[2:]
selector = 'x86_64-unknown-linux-musl'
package = root / 'vendor' / selector
metadata = json.loads((root / 'package.json').read_text())
assert metadata['name'] == '@openai/codex'
assert metadata['version'] == version + '-linux-x64'
assert metadata['os'] == ['linux'] and metadata['cpu'] == ['x64']
assert sorted(p.name for p in (root / 'vendor').iterdir()) == [selector]
canonical = json.loads((package / 'codex-package.json').read_text())
assert canonical['target'] == 'x86_64-unknown-linux-gnu'
assert canonical['version'] == version
voice = package / 'codex-resources/voice'
manifest = json.loads((voice / 'manifest.json').read_text())
assert manifest['buildCommit'] == commit and manifest['appVersion'] == version
assert manifest['appTarget'] == manifest['voiceTarget'] == 'x86_64-unknown-linux-gnu'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


for relative, expected in manifest['sha256'].items():
    assert digest(package / relative) == expected, relative
for name, relative in {
    'codex': 'bin/codex', 'codex-code-mode-host': 'bin/codex-code-mode-host',
    'bwrap': 'codex-resources/bwrap', 'zsh': 'codex-resources/zsh/bin/zsh',
    'codex-voice-host': 'codex-resources/voice/bin/codex-voice-host',
}.items():
    assert digest(package / relative) == digest(Path('/bench/raw') / name), name
assert digest(package / 'codex-resources/bwrap') == bwrap_digest
assert (package / 'codex-path/rg').is_file()
for relative in ('NOTICE.md', 'sources.json', 'licenses/LGPL-2.1.txt', 'runtime.json'):
    assert (voice / relative).is_file(), relative

# ELF dependency closure must resolve after extraction, with no build-path rpaths.
for path in package.rglob('*'):
    if not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    dynamic = subprocess.check_output(['readelf', '-dW', path], text=True, timeout=30)
    for line in dynamic.splitlines():
        if 'RPATH' in line or 'RUNPATH' in line:
            assert '/bench' not in line and '/src' not in line, (path, line)
    # Ripgrep is the upstream, manifest-verified prebuilt exception.
    if path == package / 'codex-path/rg':
        continue
    sections = subprocess.check_output(['readelf', '-SW', path], text=True, timeout=30)
    assert '.debug_info' in sections and '.symtab' in sections, path
    linked = subprocess.run(['ldd', path], capture_output=True, text=True, timeout=30)
    assert linked.returncode == 0 and 'not found' not in linked.stdout + linked.stderr, path
    for line in linked.stdout.splitlines():
        if '=> /' in line:
            resolved = Path(line.split('=> ', 1)[1].split(' ', 1)[0]).resolve()
            assert resolved.is_relative_to(package) or resolved.is_relative_to(Path('/usr/lib64')) or resolved.is_relative_to(Path('/lib64').resolve()), (path, line)
    print(f'Verified ELF closure and unstripped debug symbols: {path.relative_to(package)}')

subprocess.run([package / 'bin/codex', '--version'], check=True, timeout=30)
subprocess.run([package / 'codex-resources/zsh/bin/zsh', '-fc', 'print -r -- fedora-zsh'], check=True, timeout=30)
helper = voice / 'bin/codex-voice-host'
assert subprocess.check_output([helper, '--build-commit'], text=True, timeout=30).strip() == commit
runtime_env = {key: value for key, value in os.environ.items() if key in ('PATH', 'HOME', 'LANG', 'LC_ALL')}
runtime_env.update({key: '' for key in ('GST_PLUGIN_PATH', 'GST_PLUGIN_PATH_1_0', 'GST_PLUGIN_SYSTEM_PATH', 'GST_PLUGIN_SYSTEM_PATH_1_0')})
runtime_env.update(GST_REGISTRY='/dev/null', GST_REGISTRY_UPDATE='no', GST_REGISTRY_FORK='no')
child = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=runtime_env)


def read_exact(size):
    output = bytearray()
    deadline = time.monotonic() + 30
    while len(output) < size:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([child.stdout], [], [], remaining)[0], 'voice response timeout'
        data = os.read(child.stdout.fileno(), size - len(output))
        assert data, f'voice helper exited: {child.poll()}'
        output.extend(data)
    return output


def exchange(message, expected):
    payload = json.dumps(message).encode()
    child.stdin.write(struct.pack('>I', len(payload)) + payload)
    child.stdin.flush()
    size = struct.unpack('>I', read_exact(4))[0]
    assert 0 < size <= 128 * 1024
    response = json.loads(read_exact(size))
    assert response == {'type': expected}, response


try:
    exchange({'type': 'hello', 'protocol': 1, 'buildCommit': commit}, 'ready')
    exchange({'type': 'initializeRuntime'}, 'runtimeReady')
    exchange({'type': 'close'}, 'closed')
    child.stdin.close()
    assert child.wait(timeout=10) == 0
finally:
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)
    child.stdout.close()
    child.stderr.close()
print('Verified packed npm metadata, byte identity, relocation and voice initialization/close')
