import { execFile } from "node:child_process";
import { promisify } from "node:util";

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

export class GitHubClient {
  private tokenPromise: Promise<string> | null = null;

  async listRecentRepos(limit: number): Promise<{ viewerLogin: string; repos: RecentRepo[] }> {
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
      { first: Math.max(1, Math.min(limit, 100)) }
    );

    return {
      viewerLogin: data.viewer.login,
      repos: data.viewer.repositories.nodes.map(mapRepo)
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
      { owner, name }
    );

    if (!data.repository) {
      throw new Error(`GitHub repository not found: ${nameWithOwner}`);
    }

    return mapRepo(data.repository);
  }

  private async graphql<T>(query: string, variables: Record<string, unknown>): Promise<T> {
    const token = await this.resolveToken();
    const response = await fetch(GITHUB_GRAPHQL_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "User-Agent": "slopzooka-mac-companion"
      },
      body: JSON.stringify({
        query,
        variables
      })
    });

    if (!response.ok) {
      const message = await response.text();
      throw new Error(`GitHub API request failed with status ${response.status}: ${message}`);
    }

    const payload = (await response.json()) as GraphQLResponse<T>;
    if (payload.errors?.length) {
      const messages = payload.errors.map((error) => error.message ?? "Unknown GitHub API error");
      throw new Error(messages.join("; "));
    }

    if (!payload.data) {
      throw new Error("GitHub API returned no data.");
    }

    return payload.data;
  }

  private async resolveToken(): Promise<string> {
    if (!this.tokenPromise) {
      this.tokenPromise = (async () => {
        const envToken = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN;
        if (envToken?.trim()) {
          return envToken.trim();
        }

        const { stdout } = await execFileAsync("gh", ["auth", "token"], {
          timeout: 10_000,
          maxBuffer: 1024 * 1024
        });

        const token = stdout.trim();
        if (!token) {
          throw new Error("GitHub CLI did not return a token.");
        }

        return token;
      })();
    }

    return this.tokenPromise;
  }
}

function mapRepo(
  repo:
    | RecentReposQueryResult["viewer"]["repositories"]["nodes"][number]
    | NonNullable<RepoByNameQueryResult["repository"]>
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
      avatarUrl: repo.owner.avatarUrl
    }
  };
}

function splitNameWithOwner(nameWithOwner: string): [string, string] {
  const [owner, name] = nameWithOwner.split("/", 2);
  if (!owner || !name) {
    throw new Error(`Invalid repository identifier: ${nameWithOwner}`);
  }

  return [owner, name];
}
