// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

/**
 * Cross-platform Python launcher for npm scripts.
 * Windows: uses `py -3.11` (avoids the Store python3 stub and missing PATH entries).
 */

import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error("usage: node scripts/run-python.mjs <script-or-flag> [args...]");
  process.exit(1);
}

function run(cmd, cmdArgs) {
  const result = spawnSync(cmd, cmdArgs, {
    stdio: "inherit",
    shell: process.platform === "win32",
  });
  if (result.error) {
    console.error(result.error.message);
    if (process.platform === "win32") {
      console.error(
        "Install Python 3.11, e.g. winget install Python.Python.3.11, then retry.",
      );
    }
    process.exit(1);
  }
  process.exit(result.status === null ? 1 : result.status);
}

if (process.platform === "win32") {
  run("py", ["-3.11", ...args]);
} else {
  run("python3", args);
}
