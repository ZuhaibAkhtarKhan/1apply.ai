import { copyFileSync, cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, "dist");
const appBaseUrl = process.env.EXTENSION_APP_BASE_URL ?? "https://1apply.awssbggiki.app";

mkdirSync(dist, { recursive: true });

await esbuild.build({
  absWorkingDir: root,
  entryPoints: {
    background: "src/background/service-worker.ts",
    content: "src/content/content.ts",
    bridge: "src/bridge/bridge.ts",
    popup: "src/popup/popup.ts",
    options: "src/options/options.ts",
  },
  bundle: true,
  format: "esm",
  target: "chrome114",
  outdir: dist,
  sourcemap: true,
  logLevel: "info",
  define: {
    __EXTENSION_APP_BASE_URL__: JSON.stringify(appBaseUrl),
  },
});

for (const file of ["src/popup/popup.html", "src/popup/popup.css", "src/options/options.html"]) {
  copyFileSync(path.join(root, file), path.join(dist, path.basename(file)));
}

// Grant the configured app origin host access and the same-origin bridge script,
// so EXTENSION_APP_BASE_URL=https://<host> builds work without editing manifest.json.
const manifest = JSON.parse(readFileSync(path.join(root, "manifest.json"), "utf8"));
const appOriginPattern = `${new URL(appBaseUrl).origin}/*`;
if (!manifest.host_permissions.includes(appOriginPattern)) {
  manifest.host_permissions.push(appOriginPattern);
}
for (const script of manifest.content_scripts ?? []) {
  if (script.js?.includes("bridge.js") && !script.matches.includes(appOriginPattern)) {
    script.matches.push(appOriginPattern);
  }
}
writeFileSync(path.join(dist, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);

cpSync(path.join(root, "icons"), path.join(dist, "icons"), { recursive: true });
cpSync(path.join(root, "fonts"), path.join(dist, "fonts"), { recursive: true });

console.info("Extension written to dist/. Load unpacked from apps/extension/dist");
