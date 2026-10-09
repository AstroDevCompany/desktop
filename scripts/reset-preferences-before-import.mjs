// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

/**
 * Surfer reapplies git patches on every import. If preferences.js / preferences.xhtml
 * still contain a previous patch application, git apply fails. Reset them to the
 * mozilla tree HEAD before importing.
 */

import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const engineDir = path.join(root, "engine");

if (!fs.existsSync(path.join(engineDir, ".git"))) {
  process.exit(0);
}

const files = [
  "browser/components/preferences/preferences.js",
  "browser/components/preferences/preferences.xhtml",
];

try {
  execSync(`git checkout HEAD -- ${files.map(f => `"${f}"`).join(" ")}`, {
    cwd: engineDir,
    stdio: "inherit",
  });
} catch {
  // Non-fatal: import may still succeed if the tree is already clean.
  process.exitCode = 0;
}
