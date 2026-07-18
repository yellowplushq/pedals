import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  handleDesktopDownload,
  handleWebsiteAsset,
  MACOS_ASSET,
} from "../src/site.mjs";

function request(path, options = {}) {
  return new Request(`https://pedals.eyhn.in${path}`, options);
}

test("the stable download path redirects to the latest desktop release", async () => {
  const req = request("/download/macos");
  const response = handleDesktopDownload(
    req,
    { DESKTOP_RELEASE_REPOSITORY: "yellowplus/pedals" },
    new URL(req.url),
  );

  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get("location"),
    `https://github.com/yellowplus/pedals/releases/latest/download/${MACOS_ASSET}`,
  );
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("the short download path redirects to the canonical path", () => {
  const req = request("/download", { method: "HEAD" });
  const response = handleDesktopDownload(req, {}, new URL(req.url));

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/download/macos");
  assert.equal(response.headers.get("content-length"), "0");
});

test("an unconfigured release repository fails without a misleading link", async () => {
  const req = request("/download/macos");
  const response = handleDesktopDownload(req, {}, new URL(req.url));

  assert.equal(response.status, 503);
  assert.match(await response.text(), /not configured/i);
  assert.equal(response.headers.get("retry-after"), "300");
});

test("download handling ignores unrelated routes and mutating methods", () => {
  const unrelated = request("/styles.css");
  const post = request("/download/macos", { method: "POST" });

  assert.equal(handleDesktopDownload(unrelated, {}, new URL(unrelated.url)), null);
  assert.equal(handleDesktopDownload(post, {}, new URL(post.url)), null);
});

test("website assets receive defense-in-depth response headers", async () => {
  const req = request("/");
  const response = await handleWebsiteAsset(req, {
    ASSETS: {
      fetch: async () =>
        new Response("<!doctype html><title>Pedals</title>", {
          headers: { "content-type": "text/html; charset=utf-8" },
        }),
    },
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-frame-options"), "DENY");
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(
    response.headers.get("strict-transport-security"),
    "max-age=31536000; includeSubDomains",
  );
  assert.match(await response.text(), /Pedals/);
});

test("the one-screen homepage exposes the product promise and download CTA", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.match(html, /Your terminal\./);
  assert.match(html, /href="\/download\/macos"/);
  assert.match(html, /8-digit code/);
  assert.match(html, /Terminal bytes and encryption keys never live on the service/);
});
