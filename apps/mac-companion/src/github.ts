import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { ServiceError } from "./errors.js";

const execFileAsync = promisify(execFile);
const GITHUB_GRAPHQL_URL = "https://api.github.com/graphql";

export type RecentRepo = {
  name: string;
  nameWithOwner: string;
  url: string;
  sshUrl: string;
  pushedAt: string;
  isPrivate: boolean;
  defaultBranch: string | null;
  owner: {
    login: string;
    name: string | null;
    avatarUrl: string;
  };
};

export type RepoOwner = {
  login: string;
  name: string | null;
  avatarUrl: string;
  kind: "user" | "org";
};

type GraphQLResponse<T> = {
  data?: T;
  errors?: Array<{ message?: string }>;
};

type RecentReposQueryResult = {
  viewer: {
    login: string;
    repositories: {
      nodes: Array<{
        name: string;
        nameWithOwner: string;
        url: string;
        sshUrl: string;
        pushedAt: string;
        isPrivate: boolean;
        defaultBranchRef: { name: string } | null;
        owner: {
          login: string;
          avatarUrl: string;
          name: string | null;
        };
      }>;
    };
  };
};

type RepoByNameQueryResult = {
  repository: {
    name: string;
    nameWithOwner: string;
    url: string;
    sshUrl: string;
    pushedAt: string;
    isPrivate: boolean;
    defaultBranchRef: { name: string } | null;
    owner: {
      login: string;
      avatarUrl: string;
      name: string | null;
    };
  } | null;
};

type AvailableOwnersQueryResult = {
  viewer: {
    login: string;
    name: string | null;
    avatarUrl: string;
    organizations: {
      nodes: Array<{
        login: string;
        name: string | null;
        avatarUrl: string;
        viewerCanCreateRepositories?: boolean | null;
      }>;
    };
  };
};

export class GitHubClient {
  private tokenPromise: Promise<string> | null = null;

  async listRecentRepos(
    limit: number,
  ): Promise<{ viewerLogin: string; repos: RecentRepo[] }> {
    const data = await this.graphql<RecentReposQueryResult>(
      `
        query RecentRepos($first: Int!) {
          viewer {
            login
            repositories(
              first: $first
              affiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR]
              ownerAffiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR]
              orderBy: { field: PUSHED_AT, direction: DESC }
              isFork: false
            ) {
              nodes {
                name
                nameWithOwner
                url
                sshUrl
                pushedAt
                isPrivate
                defaultBranchRef {
                  name
                }
                owner {
                  login
                  avatarUrl
                  ... on User {
                    name
                  }
                  ... on Organization {
                    name
                  }
                }
              }
            }
          }
        }
      `,
      { first: Math.max(1, Math.min(limit, 100)) },
    );

    return {
      viewerLogin: data.viewer.login,
      repos: data.viewer.repositories.nodes.map(mapRepo),
    };
  }

  async getRepo(nameWithOwner: string): Promise<RecentRepo> {
    const [owner, name] = splitNameWithOwner(nameWithOwner);
    const data = await this.graphql<RepoByNameQueryResult>(
      `
        query RepoByName($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            name
            nameWithOwner
            url
            sshUrl
            pushedAt
            isPrivate
            defaultBranchRef {
              name
            }
            owner {
              login
              avatarUrl
              ... on User {
                name
              }
              ... on Organization {
                name
              }
            }
          }
        }
      `,
      { owner, name },
    );

    if (!data.repository) {
      throw new Error(`GitHub repository not found: ${nameWithOwner}`);
    }

    return mapRepo(data.repository);
  }

  async listAvailableOwners(): Promise<{
    viewerLogin: string;
    owners: RepoOwner[];
  }> {
    const data = await this.graphql<AvailableOwnersQueryResult>(
      `
        query AvailableOwners {
          viewer {
            login
            name
            avatarUrl
            organizations(first: 100) {
              nodes {
                login
                name
                avatarUrl
                viewerCanCreateRepositories
              }
            }
          }
        }
      `,
      {},
    );

    const owners: RepoOwner[] = [
      {
        login: data.viewer.login,
        name: data.viewer.name ?? null,
        avatarUrl: data.viewer.avatarUrl,
        kind: "user",
      },
      ...data.viewer.organizations.nodes
        .filter((org) => org.viewerCanCreateRepositories !== false)
        .map((org) => ({
          login: org.login,
          name: org.name ?? null,
          avatarUrl: org.avatarUrl,
          kind: "org" as const,
        })),
    ];

    return {
      viewerLogin: data.viewer.login,
      owners,
    };
  }

  async createRepo(input: {
    owner: string;
    repoName: string;
    visibility: "private" | "public";
    addReadme?: boolean;
  }): Promise<RecentRepo> {
    const nameWithOwner = `${input.owner}/${input.repoName}`;
    const availableOwners = await this.listAvailableOwners();
    const isAllowedOwner = availableOwners.owners.some(
      (owner) => owner.login === input.owner,
    );
    if (!isAllowedOwner) {
      throw new Error(
        `GitHub owner is not available for repo creation: ${input.owner}`,
      );
    }

    const args = [
      "repo",
      "create",
      nameWithOwner,
      input.visibility === "public" ? "--public" : "--private",
    ];

    if (input.addReadme !== false) {
      args.push("--add-readme");
    }

    await execFileAsync("gh", args, {
      timeout: 120_000,
      maxBuffer: 8 * 1024 * 1024,
    });

    return this.getRepo(nameWithOwner);
  }

  async bugReportAccount(): Promise<string> {
    return this.viewer(await this.resolveToken(true));
  }

  private async viewer(token: string): Promise<string> {
    const data = await this.graphql<{ viewer: { login: string } }>(
      "query { viewer { login } }",
      {},
      token,
    );
    return data.viewer.login;
  }

  async createBugReport(
    title: string,
    body: string,
    expectedAccount: string,
  ): Promise<string> {
    // Verify and write with one credential snapshot, even if another request
    // refreshes the CLI token concurrently. Preflight failures cannot create an issue.
    let token: string;
    try {
      token = await this.resolveToken(true);
      if ((await this.viewer(token)) !== expectedAccount)
        throw new Error("Account changed");
    } catch {
      throw new ServiceError(
        "GitHub account changed or is unavailable. Review before publishing.",
        409,
      );
    }
    const response = await fetch(
      "https://api.github.com/repos/sragss/slopzooka/issues",
      {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(12_000),
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/vnd.github+json",
          "Content-Type": "application/json",
          "User-Agent": "slopzooka-mac-companion",
        },
        body: JSON.stringify({ title, body }),
      },
    );
    if (response.status === 401 || response.status === 403)
      throw new ServiceError(
        "GitHub rejected authorization for this issue. Refresh your credentials and review again.",
        409,
      );
    // Never echo GitHub's payload: it may contain the submitted description.
    if (!response.ok)
      throw new Error(`GitHub issue request returned HTTP ${response.status}`);
    const result = (await response.json()) as { html_url?: string };
    if (
      !/^https:\/\/github\.com\/sragss\/slopzooka\/issues\/\d+$/.test(
        result.html_url ?? "",
      )
    )
      throw new Error("GitHub returned an invalid issue URL");
    return result.html_url!;
  }

  private async graphql<T>(
    query: string,
    variables: Record<string, unknown>,
    token?: string,
  ): Promise<T> {
    const resolvedToken = token ?? (await this.resolveToken());
    const response = await fetch(GITHUB_GRAPHQL_URL, {
      method: "POST",
      signal: AbortSignal.timeout(12_000),
      headers: {
        Authorization: `Bearer ${resolvedToken}`,
        "Content-Type": "application/json",
        "User-Agent": "slopzooka-mac-companion",
      },
      body: JSON.stringify({
        query,
        variables,
      }),
    });

    if (!response.ok) {
      const message = await response.text();
      throw new Error(
        `GitHub API request failed with status ${response.status}: ${message}`,
      );
    }

    const payload = (await response.json()) as GraphQLResponse<T>;
    if (payload.errors?.length) {
      const messages = payload.errors.map(
        (error) => error.message ?? "Unknown GitHub API error",
      );
      throw new Error(messages.join("; "));
    }

    if (!payload.data) {
      throw new Error("GitHub API returned no data.");
    }

    return payload.data;
  }

  private async resolveToken(refresh = false): Promise<string> {
    if (refresh) this.tokenPromise = null;
    if (!this.tokenPromise) {
      this.tokenPromise = (async () => {
        try {
          const envToken = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN;
          if (envToken?.trim()) {
            return envToken.trim();
          }

          const { stdout } = await execFileAsync("gh", ["auth", "token"], {
            timeout: 10_000,
            maxBuffer: 1024 * 1024,
          });

          const token = stdout.trim();
          if (!token) {
            throw new Error("GitHub CLI did not return a token.");
          }

          return token;
        } catch (error) {
          this.tokenPromise = null;
          throw error;
        }
      })();
    }

    return this.tokenPromise;
  }
}

function mapRepo(
  repo:
    | RecentReposQueryResult["viewer"]["repositories"]["nodes"][number]
    | NonNullable<RepoByNameQueryResult["repository"]>,
): RecentRepo {
  return {
    name: repo.name,
    nameWithOwner: repo.nameWithOwner,
    url: repo.url,
    sshUrl: repo.sshUrl,
    pushedAt: repo.pushedAt,
    isPrivate: repo.isPrivate,
    defaultBranch: repo.defaultBranchRef?.name ?? null,
    owner: {
      login: repo.owner.login,
      name: repo.owner.name ?? null,
      avatarUrl: repo.owner.avatarUrl,
    },
  };
}

function splitNameWithOwner(nameWithOwner: string): [string, string] {
  const [owner, name] = nameWithOwner.split("/", 2);
  if (!owner || !name) {
    throw new Error(`Invalid repository identifier: ${nameWithOwner}`);
  }

  return [owner, name];
}
