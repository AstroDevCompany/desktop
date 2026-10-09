/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

const { decideNetworkRequest, parseFilterList } = ChromeUtils.importESModule(
  "resource:///modules/zen/adblock/ZenAdblockPolicy.sys.mjs"
);
const { gZenAdblock } = ChromeUtils.importESModule(
  "resource:///modules/zen/adblock/ZenAdblockManager.sys.mjs"
);

const FIXTURE = [
  "||ads.example^",
  "@@||ads.example/allowed.js^",
  "news.example##.ad-slot",
].join("\n");

add_task(function test_filter_decisions() {
  const engine = parseFilterList(FIXTURE, "medium");

  const blocked = decideNetworkRequest({
    engine,
    level: "medium",
    url: "https://ads.example/banner.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(blocked.action, "cancel", "a listed ad script is blocked");

  const allowed = decideNetworkRequest({
    engine,
    level: "medium",
    url: "https://ads.example/allowed.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(allowed.action, "allow", "an exception filter allows the request");

  const heavy = decideNetworkRequest({
    engine,
    level: "heavy",
    url: "https://cdn.example/app.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(heavy.action, "cancel", "heavy blocks an unlisted third-party script");
  Assert.equal(heavy.reason, "heavy");

  const heavyException = decideNetworkRequest({
    engine,
    level: "heavy",
    url: "https://ads.example/allowed.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(
    heavyException.action,
    "allow",
    "an exception filter still allows a third-party script on Heavy"
  );

  const firstParty = decideNetworkRequest({
    engine,
    level: "heavy",
    url: "https://news.example/app.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(firstParty.action, "allow", "heavy still allows first-party scripts");

  const paused = decideNetworkRequest({
    engine,
    level: "off",
    url: "https://ads.example/banner.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(paused.action, "allow", "per-site off skips filtering");

  const cosmetics = engine.getCosmeticsFilters({
    url: "https://news.example/",
    hostname: "news.example",
    domain: "news.example",
    classes: ["ad-slot"],
    ids: [],
    hrefs: [],
    getInjectionRules: false,
    getExtendedRules: false,
    getBaseRules: true,
  });
  ok(
    cosmetics.styles.includes(".ad-slot"),
    "cosmetic filters hide the listed slot"
  );
});

add_task(function test_bootstrap_list_before_engine_is_ready() {
  const blocked = decideNetworkRequest({
    engine: null,
    level: "medium",
    url: "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(blocked.action, "cancel");
  Assert.equal(blocked.reason, "bootstrap");

  const allowed = decideNetworkRequest({
    engine: null,
    level: "medium",
    url: "https://news.example/app.js",
    sourceUrl: "https://news.example/",
    type: "script",
  });
  Assert.equal(allowed.action, "allow");
});

add_task(function test_per_site_override_uses_base_domain() {
  const url = "https://www.example.com/article";
  gZenAdblock.setOverride(url, "off");
  Assert.equal(gZenAdblock.getOverride("https://example.com/"), "off");
  Assert.equal(gZenAdblock.getEffectiveLevel(url), "off");

  gZenAdblock.setOverride(url, "heavy");
  Assert.equal(gZenAdblock.getEffectiveLevel("https://example.com/other"), "heavy");

  gZenAdblock.setOverride(url, null);
  Assert.equal(gZenAdblock.getOverride(url), null);
  Assert.equal(
    gZenAdblock.getEffectiveLevel(url),
    gZenAdblock.getGlobalLevel(),
    "clearing the override falls back to the global level"
  );
});
