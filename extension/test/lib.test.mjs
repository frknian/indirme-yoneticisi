import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

import { isCapturableUrl, isValidPort, pingApp, sendToApp } from "../lib.js";

const config = { token: "t".repeat(64), port: 38765 };

const fakeFetch = (status, sink = []) => async (url, init) => {
  sink.push({ url, init });
  return { status };
};

test("yalnızca http(s) yakalanır", () => {
  assert.equal(isCapturableUrl("https://a/b"), true);
  assert.equal(isCapturableUrl("http://a/b"), true);
  for (const bad of ["blob:https://a/1", "data:text/plain,x", "file:///x", "", undefined]) {
    assert.equal(isCapturableUrl(bad), false, String(bad));
  }
});

test("port sınırları", () => {
  assert.equal(isValidPort(38765), true);
  for (const bad of [80, 70000, 1.5, NaN]) assert.equal(isValidPort(bad), false);
});

test("istek yalnızca 127.0.0.1'e, anahtarla gider", async () => {
  const calls = [];
  const ok = await sendToApp(
    config,
    { url: "https://a/b.zip", referer: "https://a/" },
    fakeFetch(202, calls),
  );
  assert.equal(ok, true);
  assert.equal(calls[0].url, "http://127.0.0.1:38765/download");
  assert.equal(calls[0].init.headers["X-DM-Token"], config.token);
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    url: "https://a/b.zip",
    referer: "https://a/",
  });
});

test("başarısızlıkta false döner; tarayıcı indirmesi iptal edilmemeli", async () => {
  assert.equal(await sendToApp(config, { url: "https://a/b" }, fakeFetch(401)), false);
  assert.equal(await sendToApp(config, { url: "https://a/b" }, fakeFetch(500)), false);
  const offline = async () => {
    throw new TypeError("connection refused");
  };
  assert.equal(await sendToApp(config, { url: "https://a/b" }, offline), false);
});

test("anahtarsız veya blob adreste istek atılmaz", async () => {
  const calls = [];
  const fetchImpl = fakeFetch(202, calls);
  assert.equal(await sendToApp({ ...config, token: "" }, { url: "https://a/b" }, fetchImpl), false);
  assert.equal(await sendToApp(config, { url: "blob:https://a/1" }, fetchImpl), false);
  assert.equal(calls.length, 0);
});

test("http(s) olmayan referer gönderilmez", async () => {
  const calls = [];
  await sendToApp(config, { url: "https://a/b", referer: "chrome://x" }, fakeFetch(202, calls));
  assert.equal("referer" in JSON.parse(calls[0].init.body), false);
});

test("ping durumları", async () => {
  assert.equal(await pingApp(config, fakeFetch(200)), "ok");
  assert.equal(await pingApp(config, fakeFetch(401)), "bad_token");
  assert.equal(await pingApp(config, fakeFetch(500)), "offline");
  assert.equal(await pingApp({ ...config, token: "" }), "no_token");
});

test("manifest MV3 ve yetkiler dar", async () => {
  const manifest = JSON.parse(await readFile(new URL("../manifest.json", import.meta.url)));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.host_permissions, ["http://127.0.0.1/*"]);
  assert.equal(manifest.permissions.includes("cookies"), false);
  assert.equal(manifest.background.type, "module");
});

// background.js'i sahte chrome nesnesiyle gerçek olay akışından geçirir.
test("onCreated: kabulde iptal eder, rette tarayıcıya dokunmaz", async () => {
  const listeners = {};
  const on = (name) => ({ addListener: (fn) => (listeners[name] = fn) });
  const log = { canceled: [], erased: [] };
  globalThis.chrome = {
    runtime: { onInstalled: on("installed"), openOptionsPage: () => {} },
    contextMenus: { create: () => {}, onClicked: on("menu") },
    storage: { local: { get: async () => ({ token: "t".repeat(64), port: 38765, intercept: true }) } },
    downloads: {
      onCreated: on("created"),
      cancel: async (id) => log.canceled.push(id),
      erase: async (q) => log.erased.push(q.id),
    },
    action: { setBadgeBackgroundColor: async () => {}, setBadgeText: async () => {} },
  };

  const calls = [];
  let status = 202;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return { status };
  };
  await import("../background.js");

  await listeners.created({ id: 1, url: "https://a/b.zip", state: "in_progress", referrer: "https://a/" });
  assert.deepEqual(log.canceled, [1]);
  assert.deepEqual(log.erased, [1]);

  status = 401;
  await listeners.created({ id: 2, url: "https://a/c.zip", state: "in_progress" });
  assert.deepEqual(log.canceled, [1], "reddedilen indirme tarayıcıda sürmeli");

  await listeners.created({ id: 3, url: "blob:https://a/1", state: "in_progress" });
  assert.equal(calls.length, 2, "blob adresi gönderilmemeli");
});
