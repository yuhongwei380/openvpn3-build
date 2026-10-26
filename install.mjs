#!/usr/bin/env node
import { runBuild } from './scripts/build.mjs';
import { setupEnvironment } from './scripts/lib/setup.mjs';

runBuild(process.argv.slice(2), { prepareEnvironment: setupEnvironment }).catch((error) => {
  console.error(`Installation/build failed: ${error.message}`);
  process.exitCode = 1;
});
