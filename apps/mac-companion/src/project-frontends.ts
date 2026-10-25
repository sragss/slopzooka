import fs from "node:fs/promises";
import path from "node:path";
import type { Frontend } from "./frontend-discovery.js";

export type FrontendWorkspace = { workspaceId: string; worktreePath: string };
type Definition = {
  id: string;
  name: string;
  directory: string;
  default?: boolean;
};
type Project = FrontendWorkspace & { root: string; frontends?: Definition[] };

function contains(root: string, directory: string): boolean {
  const relative = path.relative(root, directory);
  return (
    relative === "" ||
    (!relative.startsWith(`..${path.sep}`) &&
      relative !== ".." &&
      !path.isAbsolute(relative))
  );
}

/** Optional hints only. Configuration never launches commands or changes routing. */
async function definitions(root: string): Promise<Definition[] | undefined> {
  let raw: string;
  try {
    raw = await fs.readFile(path.join(root, ".slopzooka.json"), "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
  if (Buffer.byteLength(raw) > 64 * 1024)
    throw new Error("Configuration exceeds 64 KB");
  const config = JSON.parse(raw);
  if (
    !config ||
    config.version !== 1 ||
    Object.keys(config).some((key) => !["version", "frontends"].includes(key))
  )
    throw new Error("Expected version 1 with an optional frontends array");
  if (config.frontends === undefined) return undefined;
  if (!Array.isArray(config.frontends) || config.frontends.length > 32)
    throw new Error("frontends must be an array of at most 32 entries");
  const ids = new Set<string>();
  let defaults = 0;
  const result: Definition[] = [];
  for (const value of config.frontends) {
    if (
      !value ||
      typeof value !== "object" ||
      Object.keys(value).some(
        (key) => !["id", "name", "directory", "default"].includes(key),
      ) ||
      typeof value.id !== "string" ||
      !/^[a-z][a-z0-9-]{0,63}$/.test(value.id) ||
      ids.has(value.id) ||
      (value.name !== undefined &&
        (typeof value.name !== "string" ||
          !value.name.trim() ||
          value.name.length > 120)) ||
      (value.directory !== undefined &&
        (typeof value.directory !== "string" || !value.directory)) ||
      (value.default !== undefined && typeof value.default !== "boolean")
    )
      throw new Error(
        "Invalid frontend: use unique ids, names, relative directories, and at most one default",
      );
    ids.add(value.id);
    if (value.default && ++defaults > 1)
      throw new Error("Only one frontend may be default");
    const directory = value.directory ?? ".";
    const resolved = path.resolve(root, directory);
    if (path.isAbsolute(directory) || !contains(root, resolved))
      throw new Error(
        `Frontend ${value.id} directory must be inside the workspace`,
      );
    let canonical = resolved;
    try {
      canonical = await fs.realpath(resolved);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    if (!contains(root, canonical))
      throw new Error(
        `Frontend ${value.id} directory resolves outside the workspace`,
      );
    result.push({
      id: value.id,
      name: value.name?.trim() ?? value.id,
      directory: canonical,
      default: value.default,
    });
  }
  return result;
}

/** One snapshot per discovery pass, shared by Portless and ordinary listeners. */
export async function projectFrontends(
  workspaces: FrontendWorkspace[],
  warnings: string[],
) {
  const projects: Project[] = [];
  for (const workspace of workspaces) {
    let root: string;
    try {
      root = await fs.realpath(workspace.worktreePath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT")
        warnings.push(`${workspace.worktreePath}: ${(error as Error).message}`);
      continue;
    }
    let frontends: Definition[] | undefined;
    try {
      frontends = await definitions(root);
    } catch (error) {
      warnings.push(
        `${path.join(root, ".slopzooka.json")}: ${(error as Error).message}`,
      );
    }
    projects.push({ ...workspace, root, frontends });
  }
  const directories = new Map<string, Promise<string | undefined>>();
  return async (frontend: Frontend, cwd?: string): Promise<Frontend> => {
    // Recompute on every refresh: edits, moved processes and port reuse must not retain ownership.
    const {
      workspaceId: _,
      frontendId: __,
      preferred: ___,
      workspaceVisible: ____,
      ...base
    } = frontend;
    if (!cwd) return base;
    if (!directories.has(cwd))
      directories.set(
        cwd,
        fs.realpath(cwd).catch(() => undefined),
      );
    const directory = await directories.get(cwd);
    if (!directory) return base;
    const matches = projects
      .filter((project) => contains(project.root, directory))
      .sort((a, b) => b.root.length - a.root.length);
    const project = matches[0];
    if (!project || matches[1]?.root === project.root) return base;
    const associated = { ...base, workspaceId: project.workspaceId };
    if (project.frontends === undefined) return associated;
    const definitions = project.frontends
      .filter((item) => contains(item.directory, directory))
      .sort((a, b) => b.directory.length - a.directory.length);
    const definition = definitions[0];
    if (definition && definitions[1]?.directory === definition.directory) {
      warnings.push(
        `Ambiguous frontend directories in ${project.root}/.slopzooka.json for ${cwd}`,
      );
      return associated;
    }
    if (!definition) return { ...associated, workspaceVisible: false };
    return {
      ...associated,
      frontendId: definition.id,
      title: definition.name,
      preferred: definition.default,
      workspaceVisible: true,
      category: "app",
    };
  };
}
