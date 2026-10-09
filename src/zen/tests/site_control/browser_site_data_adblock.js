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
    for (const level of ["light", "medium", "heavy"]) {
      ok(
        document.getElementById("zen-site-data-adblock-" + level),
        level + " level button is in the panel"
      );
    }
    ok(
      document
        .getElementById("zen-site-data-adblock-medium")
        .hasAttribute("checked"),
      "Medium is pressed when that is the global level"
    );
    ok(
      document.getElementById("zen-site-data-adblock-reset").hidden,
      "reset stays hidden until the site overrides the global level"
    );

    const heavy = document.getElementById("zen-site-data-adblock-heavy");
    const reloaded = BrowserTestUtils.browserLoaded(gBrowser.selectedBrowser);
    EventUtils.synthesizeMouseAtCenter(heavy, {});
    Assert.equal(
      gZenAdblock.getOverride(HTTPS_PAGE),
      "heavy",
      "choosing Heavy stores a per-site override"
    );
    await reloaded;

    await openSiteDataPanel();
    ok(
      document
        .getElementById("zen-site-data-adblock-heavy")
        .hasAttribute("checked"),
      "the override is pressed after reload"
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
