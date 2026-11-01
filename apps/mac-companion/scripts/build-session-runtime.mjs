import { build } from "esbuild";
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";

// A self-contained terminal runtime, retained independently of app replacement.
const root = path.resolve(import.meta.dirname, "..");
const destination = path.resolve(process.argv[2]);
await fs.mkdir(destination, { recursive: true });
await build({
  entryPoints: [path.join(root, "src/session-service.ts")],
  bundle: true,
  platform: "node",
  format: "cjs",
  external: ["node-pty", "bufferutil", "utf-8-validate"],
  outfile: path.join(destination, "service.cjs"),
});
const require = createRequire(import.meta.url);
await fs.cp(
  path.dirname(require.resolve("node-pty/package.json")),
  path.join(destination, "node_modules/node-pty"),
  {
    recursive: true,
    dereference: true,
    mode: constants.COPYFILE_FICLONE,
    filter: (source) =>
      !source.includes(
        `${path.sep}node_modules${path.sep}node-pty${path.sep}node_modules`,
      ),
  },
);
await fs.copyFile(
  process.execPath,
  path.join(destination, "node"),
  constants.COPYFILE_FICLONE,
);
await fs.chmod(path.join(destination, "node"), 0o755);
const native = path.join(
  destination,
  "node_modules/node-pty/prebuilds",
  `${process.platform}-${process.arch}`,
);
await fs.chmod(path.join(native, "spawn-helper"), 0o755);
const hash = createHash("sha256");
async function fingerprint(directory) {
  const entries = await fs.readdir(directory, { withFileTypes: true });
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) await fingerprint(file);
    else if (entry.isFile())
      hash
        .update(path.relative(destination, file))
        .update(await fs.readFile(file));
  }
}
await fingerprint(destination);
await fs.writeFile(
  path.join(destination, "runtime.json"),
  JSON.stringify({ id: hash.digest("hex") }),
);
