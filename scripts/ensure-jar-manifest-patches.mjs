// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

/**
 * Fallback for jar.mn edits if GNU patch did not apply them (context drift).
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const engineDir = path.join(root, "engine");

function patchFile(relativePath, alreadyPatched, patch) {
  const filePath = path.join(engineDir, relativePath);
  if (!fs.existsSync(filePath)) {
    console.warn(`ensure-jar-manifest: missing ${relativePath}`);
    return false;
  }
  const original = fs.readFileSync(filePath, "utf8");
  if (alreadyPatched(original)) {
    return false;
  }
  const updated = patch(original);
  if (updated === original) {
    throw new Error(
      `ensure-jar-manifest: could not patch ${relativePath} (context changed)`,
    );
  }
  fs.writeFileSync(filePath, updated, "utf8");
  console.log(`ensure-jar-manifest: updated ${relativePath}`);
  return true;
}

let changed = false;

for (const step of [
  [
    "browser/components/preferences/jar.mn",
    text => text.includes("content/browser/preferences/zen-settings.js"),
    text =>
      text.replace(
        /(content\/browser\/preferences\/widgets\/update-information\.css\s+\(widgets\/update-information\/update-information\.css\)\r?\n)(   content\/browser\/preferences\/widgets\/update-state\.mjs)/,
        "$1\n   content/browser/preferences/zen-settings.js\n$2",
      ),
  ],
  [
    "browser/base/jar.mn",
    text => text.includes("zen-assets.jar.inc.mn"),
    text => `${text.replace(/\s*$/, "\n")}\n#include content/zen-assets.jar.inc.mn\n`,
  ],
  [
    "browser/themes/shared/jar.inc.mn",
    text => text.includes("zen-sources.inc.mn"),
    text => `${text.replace(/\s*$/, "\n")}\n#include zen-sources.inc.mn\n`,
  ],
]) {
  if (patchFile(step[0], step[1], step[2])) {
    changed = true;
  }
}

if (changed) {
  console.log(
    "ensure-jar-manifest: chrome packaging manifests were repaired; rebuild the browser (mach build).",
  );
  process.exit(2);
}
