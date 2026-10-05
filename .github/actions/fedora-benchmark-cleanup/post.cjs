const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const expected = path.join(process.env.RUNNER_TEMP, 'fedora-benchmark', 'target');
if (process.env.STATE_target !== expected) {
  throw new Error('Refusing to clean an unexpected Cargo target path');
}

// Stop any container left by an interrupted build before deleting its target.
const container = spawnSync('docker', ['inspect', '--format', '{{.State.Running}}',
  'codex-fedora44-benchmark'], { encoding: 'utf8', timeout: 15000 });
if (container.status === 0 && container.stdout.trim() === 'true') {
  const stop = spawnSync('docker', ['stop', '--timeout', '15',
    'codex-fedora44-benchmark'], { stdio: 'inherit', timeout: 45000 });
  if (stop.status !== 0) throw new Error('Failed to stop benchmark container');
}
const cleanup = spawnSync('sudo', ['-n', 'python3', '-c',
  'import pathlib, shutil, sys; p = pathlib.Path(sys.argv[1]); '
  + 'shutil.rmtree(p) if p.exists() and not p.is_symlink() else None', expected],
  { stdio: 'inherit', timeout: 300000 });
if (cleanup.status !== 0) throw new Error('Failed to remove Cargo target directory');
if (fs.existsSync(expected)) throw new Error('Cargo target still exists after cleanup');
console.log(`Removed ${expected}; persistent download and sccache inputs remain.`);
