import { afterEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../scripts/delivery-settings.mjs", import.meta.url));
const projects: string[] = [];

afterEach(async () => {
  await Promise.all(projects.splice(0).map((path) => rm(path, { force: true, recursive: true })));
});

async function project(orchestration?: string) {
  const root = await mkdtemp(join(tmpdir(), "kgr-delivery-settings-"));
  projects.push(root);
  if (orchestration !== undefined) await writeFile(join(root, "ORCHESTRATION.md"), orchestration);
  return root;
}

// A consumer repository installs the skills into `.agents/skills` and links
// `.claude/skills -> ../.agents/skills`, so agents reach the script through
// that symlink. The installed copy also gets a symlinked file beside it.
async function installedThroughSymlinks() {
  const root = await project();
  const scripts = join(root, ".agents", "skills", "deliver", "scripts");
  await mkdir(scripts, { recursive: true });
  await copyFile(script, join(scripts, "delivery-settings.mjs"));
  await symlink("delivery-settings.mjs", join(scripts, "linked-settings.mjs"));
  await mkdir(join(root, ".claude"));
  await symlink(join("..", ".agents", "skills"), join(root, ".claude", "skills"));
  const linked = join(root, ".claude", "skills", "deliver", "scripts");
  return { directory: join(linked, "delivery-settings.mjs"), file: join(linked, "linked-settings.mjs") };
}

function read(root: string, path = script) {
  const run = spawnSync("node", [path, root], { encoding: "utf8" });
  return { status: run.status, stderr: run.stderr, settings: run.status === 0 && run.stdout ? JSON.parse(run.stdout) : null };
}

test("a project without ORCHESTRATION.md continues entry points to merged", async () => {
  expect(read(await project())).toEqual({
    status: 0,
    stderr: "",
    settings: { endpoint: "merged", "entry-points": "deliver", file: null, defaulted: ["endpoint", "entry-points"] },
  });
});

test("a key the file leaves out keeps its default, and prose without frontmatter sets nothing", async () => {
  expect(read(await project("---\nendpoint: 'ready-to-merge' # a person merges\nowner: platform\n---\n\n# Policy\n")).settings).toEqual({
    endpoint: "ready-to-merge",
    "entry-points": "deliver",
    file: "ORCHESTRATION.md",
    defaulted: ["entry-points"],
  });
  expect(read(await project("# Policy\n\nendpoint: ready-to-merge\n")).settings).toMatchObject({
    endpoint: "merged",
    defaulted: ["endpoint", "entry-points"],
  });
});

test("a file that still says deployed reads as merged, and is not a defaulted key", async () => {
  expect(read(await project("---\nendpoint: deployed\n---\n")).settings).toEqual({
    endpoint: "merged",
    "entry-points": "deliver",
    file: "ORCHESTRATION.md",
    defaulted: ["entry-points"],
  });
});

test("both keys are read from CRLF frontmatter", async () => {
  expect(read(await project('---\r\nendpoint: merged\r\nentry-points: "stop"\r\n---\r\n')).settings).toMatchObject({
    endpoint: "merged",
    "entry-points": "stop",
    defaulted: [],
  });
});

test("an unknown value or unterminated frontmatter fails instead of guessing", async () => {
  const unknown = read(await project("---\nendpoint: production\n---\n"));
  expect(unknown.status).toBe(1);
  expect(unknown.stderr).toContain('sets endpoint to "production"');
  const unterminated = read(await project("---\nentry-points: stop\n"));
  expect(unterminated.status).toBe(1);
  expect(unterminated.stderr).toContain("no closing ---");
});

test("the script reads settings when reached through a symlinked skills directory or file", async () => {
  const paths = await installedThroughSymlinks();
  const root = await project("---\nendpoint: ready-to-merge\n---\n");
  const expected = {
    status: 0,
    stderr: "",
    settings: { endpoint: "ready-to-merge", "entry-points": "deliver", file: "ORCHESTRATION.md", defaulted: ["entry-points"] },
  };
  expect(read(root, paths.directory)).toEqual(expected);
  expect(read(root, paths.file)).toEqual(expected);
  const invalid = read(await project("---\nendpoint: production\n---\n"), paths.directory);
  expect(invalid.status).toBe(1);
  expect(invalid.stderr).toContain('sets endpoint to "production"');
});
