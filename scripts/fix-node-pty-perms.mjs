import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const candidates = findSpawnHelpers(path.join(root, "node_modules"));

for (const candidate of candidates) {
  fs.chmodSync(candidate, 0o755);
  console.log(`[slopzooka] ensured executable bit on ${candidate}`);
}

function findSpawnHelpers(baseDir) {
  if (!fs.existsSync(baseDir)) {
    return [];
  }

  const results = [];
  walk(baseDir, 0);
  return results;

  function walk(currentDir, depth) {
    if (depth > 6) {
      return;
    }

    for (const entry of fs.readdirSync(currentDir, { withFileTypes: true })) {
      const fullPath = path.join(currentDir, entry.name);

      if (entry.isDirectory()) {
        walk(fullPath, depth + 1);
        continue;
      }

      if (entry.name === "spawn-helper" && fullPath.includes("node-pty")) {
        results.push(fullPath);
      }
    }
  }
}
