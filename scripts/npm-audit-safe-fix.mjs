#!/usr/bin/env node
/**
 * Applies semver-safe npm audit remediations (no `npm audit fix --force`).
 * Bumps the sharp override when audit still reports sharp (surfer pins an older range).
 * Verifies the sharp APIs used by @zen-browser/surfer branding before exiting.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

function run(command, args, { allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "pipe"],
  });
  if (result.status !== 0 && !allowFailure) {
    process.stderr.write(result.stderr || result.stdout || "");
    process.exit(result.status ?? 1);
  }
  return result;
}

function readAuditVulnerabilities() {
  const result = spawnSync("npm", ["audit", "--json"], {
    cwd: root,
    encoding: "utf8",
  });
  try {
    const report = JSON.parse(result.stdout || "{}");
    return report.vulnerabilities ?? {};
  } catch {
    return {};
  }
}

function readPackageJson() {
  return JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
}

function writePackageJson(pkg) {
  writeFileSync(join(root, "package.json"), `${JSON.stringify(pkg, null, 2)}\n`);
}

function npmViewVersion(name) {
  return execFileSync("npm", ["view", name, "version"], {
    cwd: root,
    encoding: "utf8",
  }).trim();
}

console.log("Running npm audit fix (semver-safe, no --force)...");
run("npm", ["audit", "fix"], { allowFailure: true });

const vulnsAfterFix = readAuditVulnerabilities();
if (vulnsAfterFix.sharp) {
  const latestSharp = npmViewVersion("sharp");
  const pkg = readPackageJson();
  const current = pkg.overrides?.sharp;
  if (current !== latestSharp) {
    console.log(`Updating sharp override: ${current ?? "(none)"} -> ${latestSharp}`);
    pkg.overrides = { ...pkg.overrides, sharp: latestSharp };
    writePackageJson(pkg);
    run("npm", ["install"]);
  } else {
    console.log(
      "sharp is still reported by audit but override is already at latest npm release; skipping bump.",
    );
  }
}

async function sharpBrandingSmokeTest() {
  const sharp = (await import("sharp")).default;
  const dir = await mkdtemp(join(tmpdir(), "sharp-smoke-"));
  try {
    const src = join(dir, "logo.png");
    await sharp({
      create: {
        width: 64,
        height: 64,
        channels: 4,
        background: { r: 20, g: 8, b: 41, alpha: 1 },
      },
    })
      .png()
      .toFile(src);
    await sharp(src).resize(512, 512).toFile(join(dir, "about-logo.png"));
    await sharp(src).resize(1024, 1024).toFile(join(dir, "about-logo@2x.png"));
    console.log(`sharp ${sharp.versions.sharp} branding smoke test passed`);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

await sharpBrandingSmokeTest();

const remaining = readAuditVulnerabilities();
const names = Object.keys(remaining);
console.log(`Remaining audit findings (${names.length}): ${names.join(", ") || "none"}`);
