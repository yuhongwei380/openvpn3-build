import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { assertBuildHost } from './build.mjs';

const environmentKeys = new Set(['PATH', 'RUSTUP_TOOLCHAIN', 'CMAKE_PREFIX_PATH', 'PKG_CONFIG_PATH', 'OPENSSL_ROOT_DIR']);

export async function setupEnvironment({ root, platform }) {
  assertBuildHost(platform);
  const directory = path.join(root, '.work', platform);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const environmentFile = path.join(directory, `environment-${randomUUID()}.json`);
  const command = platform === 'windows' ? 'powershell.exe' : 'bash';
  const args = platform === 'windows'
    ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'scripts/windows/setup.ps1')]
    : [path.join(root, 'scripts/macos/setup.sh')];
  try {
    const result = spawnSync(command, args, {
      cwd: root,
      stdio: 'inherit',
      windowsHide: true,
      env: {
        ...process.env,
        OPENVPN_BUILD_NODE: process.execPath,
        OPENVPN_BUILD_ARCH: process.arch,
        OPENVPN_BUILD_ENV_FILE: environmentFile,
      },
    });
    if (result.error || result.status !== 0) {
      throw new Error(`Dependency setup failed (${result.error?.message ?? `exit ${result.status}`}). Resolve the reported issue and rerun node install.mjs.`);
    }
    const environment = JSON.parse(await fs.readFile(environmentFile, 'utf8'));
    if (!environment || typeof environment.PATH !== 'string' || !environment.PATH) {
      throw new Error('Dependency setup did not return a usable build environment.');
    }
    for (const [key, value] of Object.entries(environment)) {
      if (!environmentKeys.has(key) || typeof value !== 'string') {
        throw new Error(`Invalid dependency setup environment entry: ${key}`);
      }
    }
    // Keep changes in this process and its children; do not rewrite shell profiles.
    Object.assign(process.env, environment);
    process.env.PATH = path.dirname(process.execPath) + path.delimiter + process.env.PATH;
  } finally {
    await fs.rm(environmentFile, { force: true });
  }
}
