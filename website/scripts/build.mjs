import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repository = resolve(root, "..");
const source = resolve(root, "public");
const destination = resolve(root, "dist");
const releaseSource = resolve(repository, "artifacts", "updates");
const distributionSource = resolve(repository, "artifacts", "distribution");
const version = (await readFile(resolve(repository, "VERSION"), "utf8")).trim();
const build = (await readFile(resolve(repository, "BUILD_NUMBER"), "utf8")).trim();
const archiveName = `Skep-${version}-${build}-macOS-arm64.zip`;
const diskImageName = `Skep-${version}-${build}-macOS-arm64.dmg`;

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await cp(source, destination, { recursive: true });

if (existsSync(resolve(releaseSource, "appcast.xml"))) {
  await mkdir(resolve(destination, "updates"), { recursive: true });
  await mkdir(resolve(destination, "downloads"), { recursive: true });
  await cp(resolve(releaseSource, "appcast.xml"), resolve(destination, "updates", "appcast.xml"));
  const releases = await readdir(releaseSource);
  for (const filename of releases.filter((candidate) =>
    /^Skep-.+-macOS-arm64\.zip(?:\.md)?$/.test(candidate)
  )) {
    const file = resolve(releaseSource, filename);
    if (existsSync(file)) await cp(file, resolve(destination, "downloads", filename));
  }
  const archive = resolve(releaseSource, archiveName);
  if (existsSync(archive)) {
    await cp(archive, resolve(destination, "downloads", "Skep-latest-macOS-arm64.zip"));
  }
}

if (existsSync(resolve(distributionSource, diskImageName))) {
  await mkdir(resolve(destination, "downloads"), { recursive: true });
  const releases = await readdir(distributionSource);
  for (const filename of releases.filter((candidate) =>
    /^Skep-.+-macOS-arm64\.dmg$/.test(candidate)
  )) {
    await cp(resolve(distributionSource, filename), resolve(destination, "downloads", filename));
  }
  await cp(
    resolve(distributionSource, diskImageName),
    resolve(destination, "downloads", "Skep-latest-macOS-arm64.dmg")
  );
}

const checksumSources = [
  resolve(releaseSource, "SHA256SUMS"),
  resolve(distributionSource, "SHA256SUMS"),
].filter(existsSync);
if (checksumSources.length > 0) {
  await mkdir(resolve(destination, "downloads"), { recursive: true });
  const manifests = await Promise.all(checksumSources.map((path) => readFile(path, "utf8")));
  await writeFile(
    resolve(destination, "downloads", "SHA256SUMS"),
    `${manifests.map((value) => value.trim()).join("\n")}\n`
  );
}

await writeFile(
  resolve(destination, "release.json"),
  `${JSON.stringify({ version, build, platform: "macOS", architecture: "arm64", installer: "dmg", channel: "open-source-beta", source: "https://github.com/storozhenko98/skep", license: "Apache-2.0" }, null, 2)}\n`
);

console.log(`Built Skep launch site at ${destination}`);
