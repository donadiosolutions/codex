const fs = require('node:fs');
const path = require('node:path');

const target = path.join(process.env.RUNNER_TEMP, 'fedora-benchmark', 'target');
fs.appendFileSync(process.env.GITHUB_STATE, `target=${target}\n`);
console.log(`Registered post-job cleanup for ${target}`);
