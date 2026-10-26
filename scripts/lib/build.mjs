import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';

const profileTarget = 'config/client.ovpn';

export function detectPlatform(value = 'auto', host = process.platform) {
  if (value !== 'auto') {
    if (value === 'windows' || value === 'macos') return value;
    throw new Error('The build platform must be windows, macos, or auto.');
  }
  const platform = { win32: 'windows', darwin: 'macos' }[host];
  if (!platform) throw new Error(`Unsupported OS: ${host}. Build on Windows or macOS.`);
  return platform;
}

export function parseOptions(args) {
  const { values } = parseArgs({
    args,
    options: {
      platform: { type: 'string' },
      profile: { type: 'string' },
      'prepare-only': { type: 'boolean' },
      'force-engine': { type: 'boolean' },
      'skip-engine': { type: 'boolean' },
      'no-auto-install-deps': { type: 'boolean' },
      help: { type: 'boolean', short: 'h' },
    },
  });
  // Prevent a platform-specific wrapper from being redirected by a second flag.
  if (args.filter((arg) => arg === '--platform' || arg.startsWith('--platform=')).length > 1) {
    throw new Error('Specify --platform only once.');
  }
  if (values.platform && !['windows', 'macos', 'auto'].includes(values.platform)) {
    throw new Error('--platform must be windows, macos, or auto.');
  }
  if (values['force-engine'] && values['skip-engine']) {
    throw new Error('--force-engine and --skip-engine cannot be combined.');
  }
  return {
    platform: values.platform,
    profile: values.profile,
    prepareOnly: Boolean(values['prepare-only']),
    forceEngine: Boolean(values['force-engine']),
    skipEngine: Boolean(values['skip-engine']),
    noAutoInstallDeps: Boolean(values['no-auto-install-deps']),
    help: Boolean(values.help),
  };
}

export function assertBuildHost(platform, host = process.platform, arch = process.arch) {
  const requiredHost = { windows: 'win32', macos: 'darwin' }[platform];
  if (!requiredHost || host !== requiredHost) {
    throw new Error(`${platform} installers must be built on ${platform}. Use --prepare-only to prepare source on another OS.`);
  }
  if (platform === 'windows' && arch !== 'x64') {
    throw new Error('Windows builds currently require an x64 Node.js environment.');
  }
  if (platform === 'macos' && !['x64', 'arm64'].includes(arch)) {
    throw new Error('macOS builds require an Intel or Apple Silicon Mac.');
  }
}

function run(command, args, { cwd, capture = false, env = process.env, allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    env,
    encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
    windowsHide: true,
  });
  if (!allowFailure && (result.error || result.status !== 0)) {
    const detail = result.error?.message ?? result.stderr?.trim() ?? '';
    throw new Error(`${command} failed (exit ${result.status ?? 'unknown'})${detail ? `: ${detail}` : '.'}`);
  }
  return result;
}

const git = (sourceDir, args, options = {}) => run('git', ['-C', sourceDir, ...args], { capture: true, ...options });
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function hashFile(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

async function exists(file) {
  try {
    await fs.lstat(file);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

export async function loadUpstream(root) {
  const upstream = JSON.parse(await fs.readFile(path.join(root, 'config/upstream.json'), 'utf8'));
  if (typeof upstream.repository !== 'string' || !upstream.repository || upstream.repository.startsWith('-')) {
    throw new Error('config/upstream.json must specify a repository URL.');
  }
  if (!/^[a-f0-9]{40}$/i.test(upstream.commit ?? '')) {
    throw new Error('config/upstream.json must pin a full 40-character commit.');
  }
  return { repository: upstream.repository, commit: upstream.commit.toLowerCase() };
}

export async function readProfile(file) {
  let contents;
  try {
    contents = await fs.readFile(file);
  } catch (error) {
    if (error.code === 'ENOENT') {
      throw new Error(`Private profile not found: ${file}. Create private/client.ovpn or pass --profile PATH.`);
    }
    throw error;
  }
  const text = contents.toString('utf8');
  if (!text.trim() || contents.includes(0)) throw new Error('The private profile must be a non-empty text file.');
  // The app writes include_bytes!(client.ovpn) to a temporary file at runtime.
  // Referenced certificate/password files would not accompany that file.
  const fileOptions = new Set([
    'ca', 'cert', 'key', 'extra-certs', 'pkcs12', 'tls-auth', 'tls-crypt', 'tls-crypt-v2',
    'crl-verify', 'auth-user-pass', 'askpass', 'http-proxy-user-pass', 'config', 'cd',
  ]);
  let inlineBlock = null;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (inlineBlock) {
      if (line.toLowerCase() === `</${inlineBlock}>`) inlineBlock = null;
      continue;
    }
    const block = line.match(/^<([a-z0-9-]+)>$/i);
    if (block && fileOptions.has(block[1].toLowerCase())) {
      inlineBlock = block[1].toLowerCase();
      continue;
    }
    if (!line || /^[#;]/.test(line)) continue;
    const option = line.replace(/\s+[;#].*$/, '').match(/^(?:--)?([a-z0-9-]+)(?:\s+(.+))?$/i);
    if (option && fileOptions.has(option[1].toLowerCase()) && option[2] && option[2] !== '[inline]') {
      throw new Error(`Profile directive "${option[1]}" references an external file. Embed its contents in the .ovpn profile before building.`);
    }
  }
  return { contents, sha256: sha256(contents) };
}

export async function withBuildLock(root, platform, action) {
  const directory = path.join(root, '.work', platform);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const lockPath = path.join(directory, 'build.lock');
  let lock;
  try {
    lock = await fs.open(lockPath, 'wx', 0o600);
  } catch (error) {
    if (error.code === 'EEXIST') {
      throw new Error(`A ${platform} build is already locked. If the previous process has exited, remove ${lockPath} and retry.`);
    }
    throw error;
  }
  try {
    await lock.writeFile(JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }));
    return await action();
  } finally {
    await lock.close();
    await fs.unlink(lockPath);
  }
}

export async function prepareSource({ root, platform, upstream, profile }) {
  const sourceDir = path.join(root, '.work', platform, 'source');
  await fs.mkdir(path.dirname(sourceDir), { recursive: true, mode: 0o700 });
  if (!await exists(sourceDir)) {
    console.log(`Fetching upstream source for ${platform}...`);
    run('git', ['init', '--quiet', sourceDir], { capture: true });
    git(sourceDir, ['remote', 'add', 'origin', upstream.repository]);
    git(sourceDir, ['config', 'core.autocrlf', 'false']);
  }
  if ((await fs.lstat(sourceDir)).isSymbolicLink() || !await exists(path.join(sourceDir, '.git'))) {
    throw new Error(`Source cache must be a dedicated Git checkout: ${sourceDir}`);
  }
  const topLevel = git(sourceDir, ['rev-parse', '--show-toplevel']).stdout.trim();
  if (await fs.realpath(topLevel) !== await fs.realpath(sourceDir)) {
    throw new Error(`Unexpected repository at ${sourceDir}. Move this cache aside and retry.`);
  }
  if (git(sourceDir, ['remote', 'get-url', 'origin']).stdout.trim() !== upstream.repository) {
    throw new Error(`Cached origin does not match config/upstream.json. Move ${sourceDir} aside and retry.`);
  }
  const head = git(sourceDir, ['rev-parse', '--verify', 'HEAD'], { allowFailure: true });
  // Upstream generators write LF on Windows. Compare normalized content rather
  // than porcelain status, which can report CRLF-only rewrites as modifications.
  const tracked = head.status === 0
    ? git(sourceDir, ['diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', 'HEAD', '--']).stdout
    : git(sourceDir, ['ls-files', '--cached', '-z']).stdout;
  const untracked = git(sourceDir, ['ls-files', '--others', '--exclude-standard', '-z']).stdout;
  const changes = (tracked + untracked).split('\0').filter(Boolean);
  if (changes.some((file) => file !== profileTarget)) {
    throw new Error(`Source cache has local changes outside ${profileTarget}. Preserve them and move ${sourceDir} aside before rebuilding.`);
  }
  if (git(sourceDir, ['cat-file', '-e', `${upstream.commit}^{commit}`], { allowFailure: true }).status !== 0) {
    git(sourceDir, ['fetch', '--depth=1', 'origin', upstream.commit], { capture: false });
  }
  if (head.status !== 0 || head.stdout.trim() !== upstream.commit) {
    if (head.status === 0 && changes.length) {
      // Only the profile is managed by this wrapper; other changes were rejected above.
      git(sourceDir, ['restore', '--source=HEAD', '--staged', '--worktree', '--', profileTarget]);
    }
    git(sourceDir, ['checkout', '--detach', upstream.commit]);
  }
  for (const relative of [profileTarget, 'build/windows/package.ps1', 'build/macos/package.sh', 'package-lock.json']) {
    const file = path.join(sourceDir, relative);
    if (!await exists(file) || !(await fs.lstat(file)).isFile()) {
      throw new Error(`Pinned upstream is missing a required regular file: ${relative}`);
    }
  }
  const destination = path.join(sourceDir, profileTarget);
  if (await fs.realpath(path.dirname(destination)) !== path.join(await fs.realpath(sourceDir), 'config')) {
    throw new Error('The upstream config directory must not point outside the source cache.');
  }
  if (!(await fs.readFile(destination)).equals(profile.contents)) {
    await fs.writeFile(destination, profile.contents, { mode: 0o600 });
  }
  await fs.chmod(destination, 0o600);
  return { sourceDir, platform, upstream, profileSha256: profile.sha256 };
}

export function packageInvocation(prepared, options, baseEnv = process.env) {
  if (prepared.platform === 'windows') {
    return {
      command: 'powershell.exe',
      args: [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        path.join(prepared.sourceDir, 'build/windows/package.ps1'),
        ...(options.forceEngine ? ['-ForceOpenVpnBuild'] : []),
        ...(options.skipEngine ? ['-SkipOpenVpnBuild'] : []),
        ...(options.noAutoInstallDeps ? ['-NoAutoInstallDeps'] : []),
      ],
      env: { ...baseEnv },
    };
  }
  return {
    command: 'bash',
    args: [path.join(prepared.sourceDir, 'build/macos/package.sh')],
    env: {
      ...baseEnv,
      FORCE_OPENVPN3_BUILD: options.forceEngine ? '1' : '0',
      SKIP_OPENVPN3_BUILD: options.skipEngine ? '1' : '0',
    },
  };
}

export async function buildPackage(prepared, options) {
  assertBuildHost(prepared.platform);
  // Require a report from this invocation so an old installer cannot pass as a new build.
  await fs.rm(path.join(prepared.sourceDir, 'build/dist/build-verification.json'), { force: true });
  const invocation = packageInvocation(prepared, options);
  run(invocation.command, invocation.args, { cwd: prepared.sourceDir, env: invocation.env });
}

export async function collectArtifacts({ root, prepared }) {
  const upstreamDist = path.join(prepared.sourceDir, 'build/dist');
  const report = JSON.parse(await fs.readFile(path.join(upstreamDist, 'build-verification.json'), 'utf8'));
  if (!Array.isArray(report.artifacts) || report.artifacts.length === 0) {
    throw new Error('The upstream build did not report any installers.');
  }
  const extension = prepared.platform === 'windows' ? '.exe' : '.dmg';
  const artifacts = [];
  const names = new Set();
  for (const entry of report.artifacts) {
    if (typeof entry.file !== 'string') throw new Error('Invalid installer path in upstream build report.');
    const file = path.resolve(prepared.sourceDir, entry.file);
    const name = path.basename(file);
    if (path.dirname(file) !== upstreamDist || path.extname(file).toLowerCase() !== extension || names.has(name)) {
      throw new Error('Upstream build reported an unexpected installer path or duplicate artifact.');
    }
    names.add(name);
    const stat = await fs.lstat(file);
    if (!stat.isFile() || stat.size === 0 || stat.size !== entry.bytes || await hashFile(file) !== entry.sha256) {
      throw new Error(`Installer does not match the upstream build report: ${name}`);
    }
    artifacts.push({ file: name, bytes: stat.size, sha256: entry.sha256 });
  }
  const builtAt = new Date().toISOString();
  const buildId = `${builtAt.replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}`;
  const outputDir = path.join(root, 'dist', prepared.platform, buildId);
  await fs.mkdir(outputDir, { recursive: true, mode: 0o700 });
  for (const artifact of artifacts) {
    await fs.copyFile(path.join(upstreamDist, artifact.file), path.join(outputDir, artifact.file), fs.constants.COPYFILE_EXCL);
    await fs.chmod(path.join(outputDir, artifact.file), 0o600);
  }
  const manifest = {
    builtAt,
    platform: prepared.platform,
    architecture: process.arch,
    upstream: prepared.upstream,
    profileSha256: prepared.profileSha256,
    artifacts,
  };
  await fs.writeFile(path.join(outputDir, 'build-info.json'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  return { outputDir, manifest };
}
