/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

const { gZenAdblock } = ChromeUtils.importESModule(
  "resource:///modules/zen/adblock/ZenAdblockManager.sys.mjs"
);

add_task(async function test_site_panel_adblock_levels() {
  const tab = BrowserTestUtils.addTab(gBrowser, HTTPS_PAGE, {
    skipAnimation: true,
  });
  await BrowserTestUtils.switchTab(gBrowser, tab);
  gZenAdblock.setOverride(HTTPS_PAGE, null);

  try {
    const panel = await openSiteDataPanel();
    Assert.equal(panel.state, "open", "panel is open");

    const section = document.getElementById("zen-site-data-adblock-section");
    ok(!section.hidden, "ad blocking section is visible on https pages");
    const levelMenu = document.getElementById("zen-site-data-adblock-level");
    ok(levelMenu, "ad blocking level selector is in the panel");
    Assert.equal(
      levelMenu.value,
      "medium",
      "Medium is selected when that is the global level"
    );
    ok(
      document.getElementById("zen-site-data-adblock-reset").hidden,
      "reset stays hidden until the site overrides the global level"
    );

    const reloaded = BrowserTestUtils.browserLoaded(gBrowser.selectedBrowser);
    levelMenu.value = "heavy";
    levelMenu.dispatchEvent(new Event("command", { bubbles: true }));
    Assert.equal(
      gZenAdblock.getOverride(HTTPS_PAGE),
      "heavy",
      "choosing Heavy stores a per-site override"
    );
    await reloaded;

    await openSiteDataPanel();
    Assert.equal(
      document.getElementById("zen-site-data-adblock-level").value,
      "heavy",
      "the override is selected after reload"
    );
    const reset = document.getElementById("zen-site-data-adblock-reset");
    ok(!reset.hidden, "reset is available while an override is set");

    const resetLoad = BrowserTestUtils.browserLoaded(gBrowser.selectedBrowser);
    EventUtils.synthesizeMouseAtCenter(reset, {});
    Assert.equal(gZenAdblock.getOverride(HTTPS_PAGE), null, "reset clears the override");
    await resetLoad;
  } finally {
    gZenAdblock.setOverride(HTTPS_PAGE, null);
    await closeSiteDataPanel();
    BrowserTestUtils.removeTab(tab);
  }
});
