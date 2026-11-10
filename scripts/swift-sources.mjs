import fs from "node:fs/promises";
import path from "node:path";

export async function swiftSources(directory) {
  return (await fs.readdir(directory))
    .filter((name) => name.endsWith(".swift"))
    .map((name) => path.join(directory, name));
}
