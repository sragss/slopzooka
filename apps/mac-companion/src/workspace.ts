import { execFile } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import type { Logger } from "./logger.js";
import type { RecentRepo } from "./github.js";
import type { TuiProfile } from "../../../packages/protocol/src/index.js";

const execFileAsync = promisify(execFile);
const DOCUMENTS_CODE_ROOT = path.join(os.homedir(), "Documents", "code");

export type LaunchWorkspaceRequest = {
  nameWithOwner: string;
  profile: TuiProfile | null;
  baseRef?: string;
};

export type LaunchWorkspaceResult = {
  repo: RecentRepo;
  localCheckoutPath: string;
  worktreePath: string;
  branchName: string;
  baseRef: string;
  launchURL: string;
  wasCloned: boolean;
  clusterId: string;
};

export class WorkspaceService {
  constructor(
    private readonly logger: Logger,
    private readonly controlOrigin: string
  ) {}

  async launchWorkspace(input: LaunchWorkspaceRequest, repo: RecentRepo): Promise<LaunchWorkspaceResult> {
    const localCheckoutPath = repoCheckoutPath(repo);
    const ensureResult = await ensureLocalCheckout(localCheckoutPath, repo, this.logger);
    await git(["-C", localCheckoutPath, "fetch", "origin", "--prune"]);

    const baseRef = await resolveBaseRef(localCheckoutPath, repo, input.baseRef);
    const branchName = makeBranchName(input.profile);
    const clusterId = crypto.randomUUID();
    const worktreePath = await reserveWorktreePath(repo, branchName);

    await git(["-C", localCheckoutPath, "worktree", "add", "-b", branchName, worktreePath, baseRef]);

    this.logger.info("Workspace launched", {
      repo: repo.nameWithOwner,
      localCheckoutPath,
      worktreePath,
      branchName,
      baseRef,
      profile: input.profile ?? "terminal",
      wasCloned: ensureResult.wasCloned
    });

    return {
      repo,
      localCheckoutPath,
      worktreePath,
      branchName,
      baseRef,
      launchURL: terminalUrl(this.controlOrigin, input.profile, worktreePath),
      wasCloned: ensureResult.wasCloned,
      clusterId
    };
  }
}

async function ensureLocalCheckout(
  localCheckoutPath: string,
  repo: RecentRepo,
  logger: Logger
): Promise<{ wasCloned: boolean }> {
  const exists = await pathExists(localCheckoutPath);
  if (!exists) {
    await fs.mkdir(path.dirname(localCheckoutPath), { recursive: true });
    logger.info("Cloning repository", {
      repo: repo.nameWithOwner,
      localCheckoutPath
    });
    await git(["clone", repo.sshUrl, localCheckoutPath]);
    return { wasCloned: true };
  }

  await assertRepoMatches(localCheckoutPath, repo);
  return { wasCloned: false };
}

async function assertRepoMatches(localCheckoutPath: string, repo: RecentRepo): Promise<void> {
  try {
    await git(["-C", localCheckoutPath, "rev-parse", "--show-toplevel"]);
  } catch {
    throw new Error(`Target path exists but is not a git repository: ${localCheckoutPath}`);
  }

  const { stdout } = await git(["-C", localCheckoutPath, "remote", "get-url", "origin"]);
  const actual = normalizeGitHubRemote(stdout.trim());
  const expected = normalizeGitHubRemote(repo.sshUrl);

  if (!actual || !expected || actual !== expected) {
    throw new Error(
      `Target path already exists for a different repository: ${localCheckoutPath} (expected ${repo.nameWithOwner})`
    );
  }
}

async function resolveBaseRef(
  localCheckoutPath: string,
  repo: RecentRepo,
  requestedBaseRef?: string
): Promise<string> {
  const orderedCandidates = unique([
    requestedBaseRef?.trim(),
    "master",
    repo.defaultBranch ?? undefined,
    "main"
  ]);

  for (const candidate of orderedCandidates) {
    const remoteRef = `refs/remotes/origin/${candidate}`;
    if (await refExists(localCheckoutPath, remoteRef)) {
      return `origin/${candidate}`;
    }

    const localRef = `refs/heads/${candidate}`;
    if (await refExists(localCheckoutPath, localRef)) {
      return candidate;
    }
  }

  const originHead = await symbolicOriginHead(localCheckoutPath);
  if (originHead) {
    return originHead;
  }

  throw new Error(`Unable to resolve a base branch for ${repo.nameWithOwner}.`);
}

async function symbolicOriginHead(localCheckoutPath: string): Promise<string | null> {
  try {
    const { stdout } = await git([
      "-C",
      localCheckoutPath,
      "symbolic-ref",
      "--short",
      "refs/remotes/origin/HEAD"
    ]);
    const value = stdout.trim();
    return value || null;
  } catch {
    return null;
  }
}

async function refExists(localCheckoutPath: string, ref: string): Promise<boolean> {
  try {
    await git(["-C", localCheckoutPath, "show-ref", "--verify", "--quiet", ref]);
    return true;
  } catch {
    return false;
  }
}

async function reserveWorktreePath(repo: RecentRepo, branchName: string): Promise<string> {
  const baseRoot = path.join(
    DOCUMENTS_CODE_ROOT,
    repo.owner.login,
    ".slopzooka",
    "worktrees",
    repo.name
  );
  await fs.mkdir(baseRoot, { recursive: true });

  for (let attempt = 0; attempt < 8; attempt += 1) {
    const suffix = attempt === 0 ? "" : `-${attempt + 1}`;
    const candidate = path.join(baseRoot, `${slugify(branchName)}${suffix}`);
    if (!(await pathExists(candidate))) {
      return candidate;
    }
  }

  throw new Error(`Unable to reserve a unique worktree path for ${repo.nameWithOwner}.`);
}

async function git(args: string[]): Promise<{ stdout: string; stderr: string }> {
  return execFileAsync("git", args, {
    timeout: 120_000,
    maxBuffer: 16 * 1024 * 1024
  });
}

function terminalUrl(controlOrigin: string, profile: TuiProfile | null, cwd: string): string {
  const url = new URL("/terminal", controlOrigin);
  url.searchParams.set("cwd", cwd);
  if (profile) {
    url.searchParams.set("profile", profile);
  }
  return url.toString();
}

function makeBranchName(profile: TuiProfile | null): string {
  const timestamp = new Date()
    .toISOString()
    .replaceAll(":", "")
    .replaceAll(".", "")
    .replace("T", "-")
    .replace("Z", "");
  const shortId = crypto.randomBytes(3).toString("hex");
  const prefix = profile ?? "terminal";
  return `slz/${prefix}-${timestamp}-${shortId}`;
}

function repoCheckoutPath(repo: RecentRepo): string {
  return path.join(DOCUMENTS_CODE_ROOT, repo.owner.login, repo.name);
}

function normalizeGitHubRemote(value: string): string | null {
  const trimmed = value.trim().replace(/\.git$/, "");
  if (trimmed.startsWith("git@github.com:")) {
    return trimmed.slice("git@github.com:".length);
  }

  if (trimmed.startsWith("ssh://git@github.com/")) {
    return trimmed.slice("ssh://git@github.com/".length);
  }

  if (trimmed.startsWith("https://github.com/")) {
    return trimmed.slice("https://github.com/".length);
  }

  return null;
}

function slugify(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
}

async function pathExists(candidate: string): Promise<boolean> {
  try {
    await fs.access(candidate);
    return true;
  } catch {
    return false;
  }
}

function unique(values: Array<string | undefined>): string[] {
  return Array.from(new Set(values.filter((value): value is string => Boolean(value))));
}
