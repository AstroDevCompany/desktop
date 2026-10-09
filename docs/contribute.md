<!--
   - This Source Code Form is subject to the terms of the Mozilla Public
   - License, v. 2.0. If a copy of the MPL was not distributed with this
   - file, You can obtain one at http://mozilla.org/MPL/2.0/.
   -->

# Branch Structure

The repository is structured as follows:

```
dev (main branch)
 | |
 | \--->-- stable (release branch)
 |   ^
 ^   |
 |   \-<- Hotfix (hotfixes directly from stable)
 |
 \-<- (features branches)
```

The `dev` branch is the main branch of the repository, and it is the default branch for the repository. The `twilight` branch is the feature branch, and it is branched off from the `dev` branch. The `stable` branch is the release branch, and it is branched off from the `dev` branch.

The `stable` branch may have hotfixes directly from the `stable` branch, and the `twilight` branch may have feature branches branched off from the `twilight` branch. This is done so that we can apply hotfixes like security patches directly to the `stable` branch without having to merge the changes from the `twilight` branch.

# Local Development Setup

Before you set up your local development environment, use `./scripts/run-macos.sh` or `./scripts/run-windows.ps1` for a guided first build, or follow the steps in the repository README. Skipping the documented setup can lead to avoidable build errors.

If `npm run import` fails while applying `preferences-js.patch` or `preferences-xhtml.patch`, the `engine/` tree usually still has an old copy of those files from a previous import. `npm run import` resets them automatically; you can also run `git -C engine checkout HEAD -- browser/components/preferences/preferences.js browser/components/preferences/preferences.xhtml` and import again.

# Code Of Conduct

Please read our [Code of Conduct](../CODE_OF_CONDUCT.md) before contributing.
