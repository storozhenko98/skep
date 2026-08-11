import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const repository = resolve(root, "..");
const read = (path) => readFile(resolve(root, "dist", path), "utf8");
const version = (await readFile(resolve(repository, "VERSION"), "utf8")).trim();
const build = (await readFile(resolve(repository, "BUILD_NUMBER"), "utf8")).trim();

const home = await read("index.html");
const privacy = await read("privacy/index.html");
const release = JSON.parse(await read("release.json"));
const vercel = JSON.parse(await readFile(resolve(root, "vercel.json"), "utf8"));

for (const phrase of [
  "Run coding agents.",
  "Open source · Apache 2.0",
  "Your agent infrastructure should not be a black box.",
  "git clone https://github.com/storozhenko98/skep.git",
  "One persistent microVM per agent",
  "Parallel agents without shared-state chaos.",
  "DOCKER + DB",
  "Google Cloud IAP",
  "Automatic service updates",
  "Developer ID signed",
  "notarized by Apple",
  "og:image:width",
  "site.webmanifest",
  "application/ld+json",
  "Does Skep run the coding agent for me?",
  "Is Skep open source?"
]) assert(home.includes(phrase), `Missing launch copy: ${phrase}`);

assert(!home.includes("Isolated compute that stays yours."), "Old abstract positioning is still present");
assert(privacy.includes("does not currently use advertising trackers"));
assert(privacy.includes('property="og:image"'));
assert(privacy.includes('rel="canonical"'));
assert.equal(release.version, version);
assert.equal(release.build, build);
assert.equal(release.installer, "dmg");
assert.equal(release.channel, "open-source-beta");
assert.equal(release.source, "https://github.com/storozhenko98/skep");
assert.equal(release.license, "Apache-2.0");

const downloadHeaders = vercel.headers.find((entry) => entry.source === "/downloads/(.*)")?.headers ?? [];
assert(
  downloadHeaders.some((entry) =>
    entry.key === "Cache-Control" && entry.value === "public, max-age=0, must-revalidate"
  ),
  "Stable installers must be revalidated so a browser cannot reuse an older build"
);

for (const asset of [
  "og.png",
  "favicon.svg",
  "favicon.ico",
  "favicon-16x16.png",
  "favicon-32x32.png",
  "apple-touch-icon.png",
  "icon-192.png",
  "icon-512.png",
  "site.webmanifest"
]) await stat(resolve(root, "dist", asset));

assert(!home.includes("__SKEP_"), "Launch page contains a build placeholder");

console.log("Skep source site checks passed");
