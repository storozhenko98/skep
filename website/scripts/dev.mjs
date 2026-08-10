import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { spawn } from "node:child_process";

const root = resolve(new URL("..", import.meta.url).pathname);
const child = spawn(process.execPath, [join(root, "scripts", "build.mjs")], { stdio: "inherit" });
await new Promise((resolveBuild, rejectBuild) => {
  child.on("exit", (code) => code === 0 ? resolveBuild() : rejectBuild(new Error(`Build exited ${code}`)));
});

const mime = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
  ".zip": "application/zip"
};

createServer((request, response) => {
  const requested = decodeURIComponent((request.url ?? "/").split("?")[0]);
  const safePath = normalize(requested).replace(/^(\.\.(\/|\\|$))+/, "");
  let file = join(root, "dist", safePath);
  if (requested === "/download") file = join(root, "dist", "downloads", "Skep-0.1.0-macOS-arm64.zip");
  if (!existsSync(file) || statSync(file).isDirectory()) file = join(file, "index.html");
  if (!existsSync(file)) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }
  response.writeHead(200, { "Content-Type": mime[extname(file)] ?? "application/octet-stream" });
  createReadStream(file).pipe(response);
}).listen(4173, "127.0.0.1", () => {
  console.log("Skep site: http://127.0.0.1:4173");
});
