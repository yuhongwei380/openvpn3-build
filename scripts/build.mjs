#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  assertBuildHost,
  buildPackage,
  collectArtifacts,
  detectPlatform,
  loadUpstream,
  parseOptions,
  prepareSource,
  readProfile,
  withBuildLock,
} from './lib/build.mjs';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const help = `Usage: node install.mjs [options]

  --platform windows|macos|auto  Build platform (default: detect current OS)
  --profile PATH               Private profile (default: private/client.ovpn)
  --prepare-only               Fetch pinned source and replace profile, without compiling
  --force-engine               Rebuild the native OpenVPN engine
  --skip-engine                Reuse an engine verified by the upstream scripts
  --no-auto-install-deps       Use existing tools without automatic installation
  -h, --help                   Show this help

The installer selects the OS, prepares dependencies, fetches source, replaces
the private profile, and builds an installer. Node.js 22+ is required.
Windows packages must be built on Windows; macOS packages on macOS.
Relative --profile paths are resolved from the current working directory.
Source: .work/<platform>/source; installers: dist/<platform>/<build-id>/`;

export async function runBuild(args = [], { root = projectRoot, prepareEnvironment } = {}) {
  const options = parseOptions(args);
  if (options.help) {
    console.log(help);
    return;
  }
  if (Number(process.versions.node.split('.')[0]) < 22) {
    throw new Error('Node.js 22 or newer is required.');
  }
  const platform = detectPlatform(options.platform);
  if (!options.prepareOnly) assertBuildHost(platform);
  console.log(`Detected build environment: ${platform} (${process.arch})`);
  const upstream = await loadUpstream(root);
  const profile = await readProfile(path.resolve(options.profile ?? path.join(root, 'private/client.ovpn')));
  await withBuildLock(root, platform, async () => {
    // Validate the private input before installing tools or downloading source.
    if (prepareEnvironment && !options.prepareOnly && !options.noAutoInstallDeps) {
      console.log('[1/3] Checking and installing build dependencies...');
      await prepareEnvironment({ root, platform });
    }
    console.log('[2/3] Preparing source and private profile...');
    const prepared = await prepareSource({ root, platform, upstream, profile });
    console.log(`Source ready: ${prepared.sourceDir}\nPinned commit: ${upstream.commit}\nPrivate profile replaced: config/client.ovpn`);
    if (options.prepareOnly) {
      console.log('Preparation completed. No compiler or packaging tools were invoked.');
      return;
    }
    console.log('[3/3] Compiling and packaging the client...');
    await buildPackage(prepared, options);
    const { outputDir } = await collectArtifacts({ root, prepared });
    console.log(`Build completed. Private installers and build-info.json: ${outputDir}`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  runBuild(process.argv.slice(2)).catch((error) => {
    console.error(`Build failed: ${error.message}`);
    process.exitCode = 1;
  });
}
