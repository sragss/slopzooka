import { ServiceError } from "./errors.js";
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
const SLOPZOOKA_HOME =
  process.env.SLOPZOOKA_HOME?.trim() || path.join(os.homedir(), ".slopzooka");
const WORKSPACES_ROOT = path.join(SLOPZOOKA_HOME, "workspaces");
const REPOS_ROOT = path.join(WORKSPACES_ROOT, "repos");
const WORKTREES_ROOT = path.join(WORKSPACES_ROOT, "worktrees");
const WORKSPACE_INDEX_PATH = path.join(WORKSPACES_ROOT, "index.json");

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
  wasCloned: boolean;
  workspaceId: string;
};

export type WorkspacePaths = {
  slopzookaHome: string;
  workspacesRoot: string;
  reposRoot: string;
  worktreesRoot: string;
  workspaceIndexPath: string;
};

export type WorkspaceRecord = {
  workspaceId: string;
  repo: RecentRepo;
  profile: TuiProfile | null;
  localCheckoutPath: string;
  worktreePath: string;
  branchName: string;
  baseRef: string;
  createdAt: string;
  updatedAt: string;
  archivedAt?: string | null;
};

export type WorkspaceSummary = WorkspaceRecord & {
  existsOnDisk: boolean;
};

// One writer owns git and index mutations. Reads remain independent and see atomic snapshots.
let mutationTail: Promise<unknown> = Promise.resolve();
function mutate<T>(operation: () => Promise<T>): Promise<T> {
  const result = mutationTail.then(operation, operation);
  mutationTail = result.catch(() => undefined);
  return result;
}

export class WorkspaceService {
  constructor(private readonly logger: Logger) {}

  launchWorkspace(
    input: LaunchWorkspaceRequest,
    repo: RecentRepo,
  ): Promise<LaunchWorkspaceResult> {
    return mutate(() => this.launch(input, repo));
  }
  private async launch(
    input: LaunchWorkspaceRequest,
    repo: RecentRepo,
  ): Promise<LaunchWorkspaceResult> {
    const localCheckoutPath = repoCheckoutPath(repo);
    const ensureResult = await ensureLocalCheckout(
      localCheckoutPath,
      repo,
      this.logger,
    );
    await git(["-C", localCheckoutPath, "fetch", "origin", "--prune"]);

    const baseRef = await resolveBaseRef(
      localCheckoutPath,
      repo,
      input.baseRef,
    );
    const branchName = makeBranchName(input.profile);
    const workspaceId = crypto.randomUUID();
    const worktreePath = await reserveWorktreePath(repo, branchName);

    await git([
      "-C",
      localCheckoutPath,
      "worktree",
      "add",
      "-b",
      branchName,
      worktreePath,
      baseRef,
    ]);

    this.logger.info("Workspace launched", {
      repo: repo.nameWithOwner,
      localCheckoutPath,
      worktreePath,
      branchName,
      baseRef,
      profile: input.profile ?? "terminal",
      wasCloned: ensureResult.wasCloned,
    });

    await upsertWorkspaceRecord({
      workspaceId,
      repo,
      profile: input.profile ?? null,
      localCheckoutPath,
      worktreePath,
      branchName,
      baseRef,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    });

    return {
      repo,
      localCheckoutPath,
      worktreePath,
      branchName,
      baseRef,
      wasCloned: ensureResult.wasCloned,
      workspaceId,
    };
  }

  async frontendWorkspaces(): Promise<WorkspaceRecord[]> {
    return (await readWorkspaceIndex()).filter((record) => !record.archivedAt);
  }

  async listWorkspaces(
    limit: number,
    includeArchived = false,
  ): Promise<WorkspaceSummary[]> {
    const records = await readWorkspaceIndex();
    const filtered = includeArchived
      ? records
      : records.filter((record) => !record.archivedAt);
    const sorted = filtered.sort((a, b) =>
      b.updatedAt.localeCompare(a.updatedAt),
    );
    const limited = sorted.slice(0, Math.max(1, Math.min(limit, 100)));

    return Promise.all(
      limited.map(async (record) => ({
        ...record,
        existsOnDisk: await pathExists(record.worktreePath),
      })),
    );
  }

  reopenWorkspace(
    workspaceId: string,
    profileOverride?: TuiProfile | null,
  ): Promise<LaunchWorkspaceResult> {
    return mutate(() => this.reopen(workspaceId, profileOverride));
  }
  private async reopen(
    workspaceId: string,
    profileOverride?: TuiProfile | null,
  ): Promise<LaunchWorkspaceResult> {
    const record = await this.requireWorkspace(workspaceId);

    if (!(await pathExists(record.worktreePath))) {
      throw new ServiceError(
        `Workspace is missing on disk: ${record.worktreePath}`,
        409,
      );
    }

    const nextProfile =
      profileOverride === undefined ? record.profile : profileOverride;
    const updatedRecord: WorkspaceRecord = {
      ...record,
      profile: nextProfile ?? null,
      updatedAt: new Date().toISOString(),
      archivedAt: null,
    };
    await upsertWorkspaceRecord(updatedRecord);

    this.logger.info("Workspace reopened", {
      repo: record.repo.nameWithOwner,
      workspaceId,
      worktreePath: record.worktreePath,
      profile: nextProfile ?? "terminal",
    });

    return {
      repo: record.repo,
      localCheckoutPath: record.localCheckoutPath,
      worktreePath: record.worktreePath,
      branchName: record.branchName,
      baseRef: record.baseRef,
      wasCloned: false,
      workspaceId,
    };
  }

  archiveWorkspace(workspaceId: string): Promise<WorkspaceSummary> {
    return mutate(() => this.archive(workspaceId));
  }
  private async archive(workspaceId: string): Promise<WorkspaceSummary> {
    const record = await this.requireWorkspace(workspaceId);

    const updatedRecord: WorkspaceRecord = {
      ...record,
      archivedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    await upsertWorkspaceRecord(updatedRecord);

    this.logger.info("Workspace archived", {
      workspaceId,
      repo: record.repo.nameWithOwner,
      worktreePath: record.worktreePath,
    });

    return {
      ...updatedRecord,
      existsOnDisk: await pathExists(updatedRecord.worktreePath),
    };
  }

  pruneMissingWorkspaces(): Promise<{ archivedCount: number }> {
    return mutate(() => this.pruneMissing());
  }
  private async pruneMissing(): Promise<{ archivedCount: number }> {
    const records = await readWorkspaceIndex();
    let archivedCount = 0;
    let mutated = false;
    const now = new Date().toISOString();
    const nextRecords: WorkspaceRecord[] = [];

    for (const record of records) {
      const existsOnDisk = await pathExists(record.worktreePath);
      if (!existsOnDisk && !record.archivedAt) {
        archivedCount += 1;
        mutated = true;
        nextRecords.push({
          ...record,
          archivedAt: now,
          updatedAt: now,
        });
        continue;
      }

      nextRecords.push(record);
    }

    if (mutated) {
      await writeWorkspaceIndex(nextRecords);
      this.logger.info("Pruned missing workspaces", {
        archivedCount,
      });
    }

    return { archivedCount };
  }

  async getWorkspace(workspaceId: string): Promise<WorkspaceSummary> {
    const record = await this.requireWorkspace(workspaceId);
    return {
      ...record,
      existsOnDisk: await pathExists(record.worktreePath),
    };
  }

  private async requireWorkspace(
    workspaceId: string,
  ): Promise<WorkspaceRecord> {
    const records = await readWorkspaceIndex();
    const record = records.find(
      (candidate) => candidate.workspaceId === workspaceId,
    );
    if (!record) {
      throw new ServiceError(`Workspace not found: ${workspaceId}`, 404);
    }

    return record;
  }
}

export function workspacePaths(): WorkspacePaths {
  return {
    slopzookaHome: SLOPZOOKA_HOME,
    workspacesRoot: WORKSPACES_ROOT,
    reposRoot: REPOS_ROOT,
    worktreesRoot: WORKTREES_ROOT,
    workspaceIndexPath: WORKSPACE_INDEX_PATH,
  };
}

async function readWorkspaceIndex(): Promise<WorkspaceRecord[]> {
  try {
    const data = await fs.readFile(WORKSPACE_INDEX_PATH, "utf8");
    const payload = JSON.parse(data) as unknown;
    if (!Array.isArray(payload)) throw new Error("Invalid workspace index");

    const records = payload.map((value) => {
      if (!value || typeof value !== "object") return value;
      const { clusterId, ...record } = value;
      return { ...record, workspaceId: record.workspaceId ?? clusterId };
    });
    if (!records.every(isWorkspaceRecord))
      throw new Error(
        "Workspace index contains invalid records; restore it from backup before writing",
      );
    return records;
  } catch (error) {
    const err = error as NodeJS.ErrnoException;
    if (err.code === "ENOENT") {
      return [];
    }

    throw error;
  }
}

async function upsertWorkspaceRecord(record: WorkspaceRecord): Promise<void> {
  const existing = await readWorkspaceIndex();
  const next = existing.filter(
    (candidate) => candidate.workspaceId !== record.workspaceId,
  );
  next.push(record);
  next.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));

  await writeWorkspaceIndex(next);
}

async function writeWorkspaceIndex(records: WorkspaceRecord[]): Promise<void> {
  await fs.mkdir(WORKSPACES_ROOT, { recursive: true });
  const tempPath = `${WORKSPACE_INDEX_PATH}.${crypto.randomUUID()}.tmp`;
  await fs.writeFile(tempPath, JSON.stringify(records, null, 2) + "\n", "utf8");
  await fs.rename(tempPath, WORKSPACE_INDEX_PATH);
}

async function ensureLocalCheckout(
  localCheckoutPath: string,
  repo: RecentRepo,
  logger: Logger,
): Promise<{ wasCloned: boolean }> {
  const exists = await pathExists(localCheckoutPath);
  if (!exists) {
    await fs.mkdir(path.dirname(localCheckoutPath), { recursive: true });
    logger.info("Cloning repository", {
      repo: repo.nameWithOwner,
      localCheckoutPath,
    });
    await git(["clone", repo.sshUrl, localCheckoutPath]);
    return { wasCloned: true };
  }

  await assertRepoMatches(localCheckoutPath, repo);
  return { wasCloned: false };
}

async function assertRepoMatches(
  localCheckoutPath: string,
  repo: RecentRepo,
): Promise<void> {
  try {
    await git(["-C", localCheckoutPath, "rev-parse", "--show-toplevel"]);
  } catch {
    throw new ServiceError(
      `Target path exists but is not a git repository: ${localCheckoutPath}`,
      409,
    );
  }

  const { stdout } = await git([
    "-C",
    localCheckoutPath,
    "config",
    "--get",
    "remote.origin.url",
  ]);
  const actual = normalizeGitHubRemote(stdout.trim());
  const expected = normalizeGitHubRemote(repo.sshUrl);

  if (!actual || !expected || actual !== expected) {
    throw new ServiceError(
      `Target path already exists for a different repository: ${localCheckoutPath} (expected ${repo.nameWithOwner})`,
      409,
    );
  }
}

export async function resolveBaseRef(
  localCheckoutPath: string,
  repo: RecentRepo,
  requestedBaseRef?: string,
): Promise<string> {
  if (requestedBaseRef?.trim()) {
    const ref = requestedBaseRef.trim();
    for (const [full, short] of [
      [`refs/remotes/origin/${ref}`, `origin/${ref}`],
      [`refs/heads/${ref}`, ref],
    ] as const) {
      if (await refExists(localCheckoutPath, full)) return short;
    }
    throw new ServiceError(`Requested branch does not exist: ${ref}`, 422);
  }
  const originHead = await symbolicOriginHead(localCheckoutPath);
  const orderedCandidates = unique([
    repo.defaultBranch ?? undefined,
    "main",
    "master",
  ]);
  if (!repo.defaultBranch && originHead) return originHead;

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

  if (originHead) {
    return originHead;
  }

  throw new ServiceError(
    `Unable to resolve a base branch for ${repo.nameWithOwner}.`,
    422,
  );
}

async function symbolicOriginHead(
  localCheckoutPath: string,
): Promise<string | null> {
  try {
    const { stdout } = await git([
      "-C",
      localCheckoutPath,
      "symbolic-ref",
      "--short",
      "refs/remotes/origin/HEAD",
    ]);
    const value = stdout.trim();
    return value || null;
  } catch {
    return null;
  }
}

async function refExists(
  localCheckoutPath: string,
  ref: string,
): Promise<boolean> {
  try {
    await git([
      "-C",
      localCheckoutPath,
      "show-ref",
      "--verify",
      "--quiet",
      ref,
    ]);
    return true;
  } catch {
    return false;
  }
}

async function reserveWorktreePath(
  repo: RecentRepo,
  branchName: string,
): Promise<string> {
  const baseRoot = path.join(WORKTREES_ROOT, repo.owner.login, repo.name);
  await fs.mkdir(baseRoot, { recursive: true });

  for (let attempt = 0; attempt < 8; attempt += 1) {
    const suffix = attempt === 0 ? "" : `-${attempt + 1}`;
    const candidate = path.join(baseRoot, `${slugify(branchName)}${suffix}`);
    if (!(await pathExists(candidate))) {
      return candidate;
    }
  }

  throw new ServiceError(
    `Unable to reserve a unique worktree path for ${repo.nameWithOwner}.`,
    409,
  );
}

async function git(
  args: string[],
): Promise<{ stdout: string; stderr: string }> {
  return execFileAsync("git", args, {
    timeout: 120_000,
    maxBuffer: 16 * 1024 * 1024,
  });
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
  return path.join(REPOS_ROOT, repo.owner.login, repo.name);
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
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
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
  return Array.from(
    new Set(values.filter((value): value is string => Boolean(value))),
  );
}

function isWorkspaceRecord(value: unknown): value is WorkspaceRecord {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const candidate = value as Partial<WorkspaceRecord>;
  return (
    typeof candidate.workspaceId === "string" &&
    typeof candidate.localCheckoutPath === "string" &&
    typeof candidate.worktreePath === "string" &&
    typeof candidate.branchName === "string" &&
    typeof candidate.baseRef === "string" &&
    typeof candidate.createdAt === "string" &&
    typeof candidate.updatedAt === "string" &&
    typeof candidate.repo?.nameWithOwner === "string"
  );
}
