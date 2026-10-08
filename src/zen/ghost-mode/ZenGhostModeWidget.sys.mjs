/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

const { PrivateBrowsingUtils } = ChromeUtils.importESModule(
  "resource://gre/modules/PrivateBrowsingUtils.sys.mjs"
);

export const ZenGhostModeWidget = {
  id: "zen-ghost-mode-button",
  l10nId: "zen-ghost-mode-button",
  overflows: false,

  onBeforeCreated() {
    return PrivateBrowsingUtils.enabled;
  },

  onCreated(node) {
    node.setAttribute("command", "Tools:PrivateBrowsing");
    node.classList.add("zen-sidebar-action-button");
    const sprite = node.ownerDocument.createXULElement("box");
    sprite.classList.add("zen-ghost-sprite");
    node.appendChild(sprite);
  },
};
