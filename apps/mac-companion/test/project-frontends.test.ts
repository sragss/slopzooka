import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { FrontendService } from "../src/frontends.js";
import { projectFrontends } from "../src/project-frontends.js";
import type { Frontend, LocalListener } from "../src/frontend-discovery.js";

const frontend: Frontend = {
  id: "test",
  hostname: "localhost",
  title: "Original",
  url: "http://localhost:3000/",
  port: 3000,
  source: "local",
  status: "ready",
  transport: "gateway",
  category: "app",
};
const logger = {
  info() {},
  warn() {},
  error() {},
  logDir: "",
  logFilePath: "",
};

test("automatic association uses canonical worktree boundaries, not package names", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-association-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const roots = ["repo", "repo-other", "repo/nested"];
  for (const root of roots)
    await fs.mkdir(path.join(home, root, "apps/web"), { recursive: true });
  await fs.symlink(path.join(home, "repo/apps/web"), path.join(home, "link"));
  const warnings: string[] = [];
  const associate = await projectFrontends(
    roots.map((root) => ({
      workspaceId: root,
      worktreePath: path.join(home, root),
    })),
    warnings,
  );
  assert.equal(
    (await associate(frontend, path.join(home, "repo/apps/web"))).workspaceId,
    "repo",
  );
  assert.equal(
    (await associate(frontend, path.join(home, "repo-other/apps/web")))
      .workspaceId,
    "repo-other",
  );
  assert.equal(
    (await associate(frontend, path.join(home, "repo/nested/apps/web")))
      .workspaceId,
    "repo/nested",
  );
  assert.equal(
    (await associate(frontend, path.join(home, "link"))).workspaceId,
    "repo",
  );
  assert.equal((await associate(frontend, home)).workspaceId, undefined);
  const stale = {
    ...frontend,
    workspaceId: "old",
    frontendId: "web",
    preferred: true,
  };
  assert.equal((await associate(stale, home)).workspaceId, undefined);
  assert.equal((await associate(stale)).frontendId, undefined);
  assert.deepEqual(warnings, []);
});

test("optional hints distinguish automatic, multiple and zero frontends; invalid hints preserve discovery with details", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-config-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  for (const directory of ["apps/web", "apps/admin", "backend"])
    await fs.mkdir(path.join(home, directory), { recursive: true });
  const workspaces = [{ workspaceId: "workspace", worktreePath: home }];
  const config = path.join(home, ".slopzooka.json");
  const warnings: string[] = [];
  const write = (frontends: unknown) =>
    fs.writeFile(config, JSON.stringify({ version: 1, frontends }));
  await write([
    { id: "web", name: "Website", directory: "apps/web", default: true },
    { id: "admin", directory: "apps/admin" },
  ]);
  let associate = await projectFrontends(workspaces, warnings);
  const web = await associate(frontend, path.join(home, "apps/web"));
  assert.equal(web.title, "Website");
  assert.equal(web.frontendId, "web");
  assert.equal(web.preferred, true);
  assert.equal(
    (await associate(frontend, path.join(home, "apps/admin"))).frontendId,
    "admin",
  );
  assert.equal(
    (await associate(frontend, path.join(home, "backend"))).workspaceVisible,
    false,
  );
  await write([{ id: "web" }, { id: "admin" }]);
  associate = await projectFrontends(workspaces, warnings);
  const ambiguous = await associate(frontend, home);
  assert.equal(ambiguous.workspaceId, "workspace");
  assert.equal(ambiguous.frontendId, undefined);
  assert.match(warnings.at(-1)!, /Ambiguous/);
  await write([]);
  associate = await projectFrontends(workspaces, warnings);
  const none = await associate(frontend, home);
  assert.equal(none.workspaceVisible, false);
  assert.equal(none.category, "app", "global catalog still exposes the app");
  await write(undefined);
  associate = await projectFrontends(workspaces, warnings);
  assert.equal((await associate(frontend, home)).workspaceVisible, undefined);
  for (const invalid of [
    [{ id: "web", directory: "../outside" }],
    [{ id: "web" }, { id: "web" }],
    [
      { id: "web", default: true },
      { id: "admin", default: true },
    ],
  ]) {
    await write(invalid);
    const count = warnings.length;
    associate = await projectFrontends(workspaces, warnings);
    assert.equal(warnings.length, count + 1);
    assert.match(warnings.at(-1)!, /\.slopzooka\.json/);
    assert.equal((await associate(frontend, home)).workspaceId, "workspace");
  }
  await fs.symlink(os.tmpdir(), path.join(home, "escape"));
  await write([{ id: "web", directory: "escape" }]);
  await projectFrontends(workspaces, warnings);
  assert.match(warnings.at(-1)!, /outside the workspace/);
  await fs.writeFile(config, "{partial");
  associate = await projectFrontends(workspaces, warnings);
  assert.equal((await associate(frontend, home)).title, "Original");
  assert.match(warnings.at(-1)!, /\.slopzooka\.json/);
});

test("catalog associates Portless, local and saved URLs; edits and port reuse never retain old ownership", async (t) => {
  const home = await fs.mkdtemp(
    path.join(os.tmpdir(), "slz-catalog-association-"),
  );
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const first = path.join(home, "first");
  const second = path.join(home, "second");
  await fs.mkdir(first);
  await fs.mkdir(second);
  const stateDir = path.join(home, "portless");
  await fs.mkdir(stateDir);
  const server = http.createServer((_req, res) => {
    res.setHeader("Content-Type", "text/html");
    res.end("ok");
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const port = (server.address() as AddressInfo).port;
  let listeners: LocalListener[] = [
    {
      pid: process.pid + 100,
      command: "test",
      cwd: first,
      host: "127.0.0.1",
      port,
    },
  ];
  const manager = new FrontendService(logger, {
    home,
    stateDir,
    listeners: async () => listeners,
    workspaces: async () => [
      { workspaceId: "first", worktreePath: first },
      { workspaceId: "second", worktreePath: second },
    ],
  });
  t.after(() => manager.stop());
  await fs.writeFile(
    path.join(first, ".slopzooka.json"),
    JSON.stringify({ version: 1, frontends: [{ id: "web", name: "Website" }] }),
  );
  let catalog = await manager.getCatalog();
  assert.equal(catalog.warning, null);
  assert.equal(catalog.frontends[0]!.workspaceId, "first");
  assert.equal(catalog.frontends[0]!.title, "Website");
  const firstPreview = await manager.openFrontend(catalog.frontends[0]!.id);
  await fs.writeFile(path.join(first, ".slopzooka.json"), "{broken");
  catalog = await manager.getCatalog();
  assert.match(catalog.warning!, /\.slopzooka\.json/);
  assert.notEqual(catalog.frontends[0]!.title, "Website");
  listeners = [{ ...listeners[0]!, pid: process.pid + 101, cwd: second }];
  catalog = await manager.getCatalog();
  assert.equal(catalog.frontends[0]!.workspaceId, "second");
  assert.equal(catalog.frontends[0]!.frontendId, undefined);
  const secondPreview = await manager.openFrontend(catalog.frontends[0]!.id);
  assert.notEqual(
    secondPreview.accessToken,
    firstPreview.accessToken,
    "ownership changes revoke the old gateway",
  );
  await manager.addURL(`http://localhost:${port}/admin`);
  catalog = await manager.getCatalog();
  assert.equal(catalog.frontends[0]!.source, "manual");
  assert.equal(catalog.frontends[0]!.workspaceId, "second");
  await fs.writeFile(path.join(stateDir, "proxy.port"), "1355");
  await fs.writeFile(
    path.join(stateDir, "routes.json"),
    JSON.stringify([{ hostname: "app.localhost", port, pid: 0 }]),
  );
  catalog = await manager.getCatalog();
  assert.equal(
    catalog.frontends.find((f) => f.source === "portless")!.workspaceId,
    "second",
  );
  // Same port on different addresses: attribution must not depend on listener order.
  listeners.push({
    ...listeners[0]!,
    pid: process.pid + 102,
    cwd: first,
    host: "::1",
  });
  catalog = await manager.getCatalog();
  assert.equal(
    catalog.frontends.find((f) => f.source === "portless")!.workspaceId,
    undefined,
  );
});
