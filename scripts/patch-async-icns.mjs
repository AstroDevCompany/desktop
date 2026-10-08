#!/usr/bin/env node
/**
 * async-icns uses fs.rmdir(path, { recursive: true }), which Node 20.12+ rejects.
 * Surfer uses async-icns when applying branding on macOS.
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const icnsPath = join(process.cwd(), "node_modules/async-icns/icns.js");

if (!existsSync(icnsPath)) {
  process.exit(0);
}

let source = readFileSync(icnsPath, "utf8");
const needle = "await rmdir(tmpDirectory, { recursive: true })";
if (!source.includes(needle)) {
  if (source.includes("await rm(tmpDirectory, { recursive: true, force: true })")) {
    process.exit(0);
  }
  console.warn("patch-async-icns: unexpected async-icns/icns.js; skipping");
  process.exit(0);
}

source = source.replace(
  "const { mkdir, rmdir } = require('fs/promises')",
  "const { mkdir, rm } = require('fs/promises')"
);
source = source.replace(
  needle,
  "await rm(tmpDirectory, { recursive: true, force: true })"
);

writeFileSync(icnsPath, source);
