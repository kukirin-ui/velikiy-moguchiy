// The Worker end to end with a fake KV and a fake network (GitHub API, Hugging Face Hub, the exclusions journal).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { beforeEach, test } from "node:test";
import worker from "../src/index.js";
import { b64encode, canonicalJson, CONTRIBUTION_DOMAIN, hex, sha256, UPDATE_DOMAIN } from "../src/lib.js";

const defaults = JSON.parse(readFileSync(new URL("../src/defaults.json", import.meta.url), "utf8"));
const ch = "UC" + "x".repeat(22);
const enc = new TextEncoder();
let hub, kv, env;

function fakeKv() {
  const m = new Map();
  return { m, get: async (k) => (m.has(k) ? m.get(k) : null), put: async (k, v) => void m.set(k, v) };
}

const users = {
  "tok-alice": { login: "alice", id: 1, created_at: "2015-01-01T00:00:00Z", type: "User" },
  "tok-bob": { login: "bob", id: 2, created_at: "2015-01-01T00:00:00Z", type: "User" },
};

function pool() {
  const lines = [];
  for (let i = 0; i < 30; i++) {
    lines.push(JSON.stringify({ video_id: `v${String(i).padStart(10, "0")}`, channel_id: i % 3 === 0 ? ch : "UCok",
                                segments: [{ start: 1, end: 3, text: `фраза ${i}` }, { start: 4, end: 6, text: "ещё" }] }));
  }
  return lines.join("\n");
}

globalThis.fetch = async (input, init = {}) => {
  const url = new URL(typeof input === "string" ? input : input.url);
  const auth = (init.headers && (init.headers.Authorization || init.headers.authorization)) || "";
  const ok = (body, status = 200) => new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
  if (url.host === "api.github.com") {
    const u = users[auth.replace("Bearer ", "")];
    return u ? ok(u) : ok({ message: "Bad credentials" }, 401);
  }
  if (url.host === "raw.githubusercontent.com") return ok(`# id\tdate\n${ch}\t2026-10-14\n`);
  if (url.host === "lfs.example") {
    hub.lfs.push(new Uint8Array(await new Response(init.body).arrayBuffer()).length);
    return ok("");
  }
  const p = url.pathname;
  if (p === "/o/models/resolve/main/index.json") return ok(hub.index);
  if (p.startsWith("/datasets/o/inbox/resolve/main/")) {
    assert.equal(auth, "Bearer hf-secret");
    const path = p.slice("/datasets/o/inbox/resolve/main/".length);
    if (path === "pool/shards/index.json") return ok({ shards: 1 });
    if (path === "pool/shards/00000.jsonl") return ok(pool());
    return ok("", 404);
  }
  if (p === "/api/datasets/o/inbox/preupload/main") {
    const body = JSON.parse(init.body);
    return ok({ files: body.files.map((f) => ({ path: f.path, uploadMode: f.path.endsWith(".safetensors") ? "lfs" : "regular" })) });
  }
  if (p === "/datasets/o/inbox.git/info/lfs/objects/batch") {
    const o = JSON.parse(init.body).objects[0];
    return ok({ objects: [{ ...o, actions: { upload: { href: "https://lfs.example/put", header: {} } } }] });
  }
  if (p === "/api/datasets/o/inbox/commit/main") {
    hub.commits.push(init.body.split("\n").map((l) => JSON.parse(l)));
    return ok({ success: true });
  }
  throw new Error(`unexpected fetch ${url}`);
};

beforeEach(() => {
  hub = { index: { spec_hash: defaults.spec.spec_hash, current: 3, versions: [{ version: 2 }, { version: 3 }] }, commits: [], lfs: [] };
  kv = fakeKv();
  env = { LIMITS: kv, HF_TOKEN: "hf-secret", FL_TASK_SECRET: "t".repeat(32), FL_INBOX: "hf:o/inbox", FL_MODELS: "hf:o/models",
          FL_GITHUB_CLIENT_ID: "cid", FL_MAX_UPDATES_PER_DAY: "2", FL_MAX_TASKS_PER_DAY: "2", FL_VIDEOS_PER_TASK: "5" };
});

const call = (path, { method = "GET", token, body, headers = {} } = {}) => worker.fetch(new Request(`https://w.example${path}`, {
  method, body, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers } }), env);

async function update(token, task, { base = 3, seed = 1, examples = 8 } = {}) {
  const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
  const header = {};
  let off = 0;
  for (const t of defaults.spec.tensors) {
    const n = 2 * t.shape.reduce((a, b) => a * b, 1);
    header[t.name] = { dtype: "F16", shape: t.shape, data_offsets: [off, off + n] };
    off += n;
  }
  const h = enc.encode(JSON.stringify(header));
  const payload = new Uint8Array(8 + h.length + off);
  new DataView(payload.buffer).setBigUint64(0, BigInt(h.length), true);
  payload.set(h, 8);
  payload[payload.length - 1] = seed;
  const m = { schema_version: 2, client_id: hex((await sha256(pub)).slice(0, 16)), public_key: b64encode(pub), base_version: base,
              spec_id: defaults.spec.spec_id, spec_hash: defaults.spec.spec_hash, num_examples: examples,
              payload_sha256: hex(await sha256(payload)), payload_bytes: payload.length, payload_dtype: "float16" };
  const sign = async (domain, text) => b64encode(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, keys.privateKey,
                                                                                    enc.encode(domain + text))));
  const c = { schema_version: 2, client_id: m.client_id, payload_sha256: m.payload_sha256, base_version: base,
              task_token: task.token, data_seconds: 60, training_steps: 50, num_clips: examples, credit_public: true };
  const form = new FormData();
  form.append("manifest", new Blob([JSON.stringify({ manifest: m, signature: await sign(UPDATE_DOMAIN, canonicalJson(m)) })]), "m.json");
  form.append("payload", new Blob([payload]), "p.safetensors");
  form.append("contribution", new Blob([JSON.stringify({ contribution: c,
    signature: await sign(CONTRIBUTION_DOMAIN, canonicalJson(c, new Set(["data_seconds"]))) })]), "c.json");
  const req = new Request("https://w.example/v1/updates", { method: "POST", body: form });
  const body = new Uint8Array(await req.arrayBuffer());
  return call("/v1/updates", { method: "POST", token, body,
                               headers: { "Content-Type": req.headers.get("content-type"), "Content-Length": String(body.length) } });
}

test("config and health need no login", async () => {
  assert.equal((await (await call("/v1/config")).json()).github_client_id, "cid");
  assert.equal((await (await call("/v1/health")).json()).latest_version, 3);
  assert.equal((await call("/v1/model/3/adapter")).status, 404);
});

test("tasks: login, exclusions, no repeats, daily limit", async () => {
  assert.equal((await call("/v1/task")).status, 401);
  assert.equal((await call("/v1/task", { token: "nope" })).status, 401);
  const t1 = await (await call("/v1/task", { token: "tok-alice" })).json();
  assert.equal(t1.videos.length, 5);
  assert.equal(t1.base_version, 3);
  assert.ok(t1.videos.every((v) => Number(v.video_id.slice(1)) % 3 !== 0), "excluded channel handed out");
  const t2 = await (await call("/v1/task", { token: "tok-alice" })).json();
  assert.equal(new Set([...t1.videos, ...t2.videos].map((v) => v.video_id)).size, 10);
  const r = await call("/v1/task", { token: "tok-alice" });
  assert.equal(r.status, 429);
  assert.ok(Number(r.headers.get("Retry-After")) > 0);
});

test("updates: accepted into the inbox once, then duplicate, conflict, stale, wrong task", async () => {
  const task = await (await call("/v1/task", { token: "tok-alice" })).json();
  const r = await update("tok-alice", task);
  const body = await r.json();
  assert.equal(r.status, 200, JSON.stringify(body));
  assert.equal(body.status, "accepted");
  const [commit] = hub.commits;
  const paths = commit.slice(1).map((l) => l.value.path);
  assert.deepEqual(paths.map((p) => p.split("/").pop()), ["manifest.json", "payload.safetensors", "contribution.json", "meta.json"]);
  assert.match(paths[0], /^pending\/alice\/v000003-\d{10}-[0-9a-f]{16}\/manifest\.json$/);
  assert.equal(commit[2].key, "lfsFile");
  assert.equal(hub.lfs[0], commit[2].value.size);
  const meta = JSON.parse(atob(commit[4].value.content));
  assert.equal(meta.login, "alice");
  assert.equal(meta.task.seconds_max, task.seconds_max);
  assert.equal((await (await update("tok-alice", task)).json()).status, "duplicate");
  assert.equal((await (await update("tok-alice", task, { seed: 2 })).json()).error, "conflict");
  assert.equal((await (await update("tok-alice", task, { base: 2 })).json()).error, "stale_base");
  const bobTask = await (await call("/v1/task", { token: "tok-bob" })).json();
  assert.equal((await (await update("tok-alice", bobTask)).json()).error, "bad_task");
  assert.equal(hub.commits.length, 1);
});

test("updates: unknown spec layout and pickle never reach the inbox", async () => {
  const task = await (await call("/v1/task", { token: "tok-bob" })).json();
  const form = new FormData();
  form.append("manifest", new Blob(["{}"]), "m");
  form.append("payload", new Blob([new Uint8Array([0x80, 4, 0x95])]), "p");
  form.append("contribution", new Blob(["{}"]), "c");
  form.append("video", new Blob(["x"]), "v.mp4");
  const req = new Request("https://w.example/v1/updates", { method: "POST", body: form });
  const body = new Uint8Array(await req.arrayBuffer());
  const r = await call("/v1/updates", { method: "POST", token: "tok-bob", body,
                                        headers: { "Content-Type": req.headers.get("content-type"), "Content-Length": String(body.length) } });
  assert.equal(r.status, 422);
  assert.equal(hub.commits.length, 0);
  assert.ok(task.token);
});

test("updates: more examples than the task's segments are refused", async () => {
  const task = await (await call("/v1/task", { token: "tok-bob" })).json();
  const total = task.videos.reduce((a, v) => a + v.segments.length, 0);
  assert.ok(total < 30);
  const r = await update("tok-bob", task, { examples: 30 });
  assert.equal((await r.json()).error, "bad_task");
  assert.equal(hub.commits.length, 0);
});
