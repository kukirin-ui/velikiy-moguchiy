import assert from "node:assert/strict";
import { test } from "node:test";
import {
  ProtocolError, canonicalJson, checkSafetensors, parseExclusions, parseGithubUser, parsePool, pickVideos, pyFloat,
  rateCheck, signClaims, verifyToken,
} from "../src/lib.js";

const code = async (f) => {
  try {
    await f();
    return "ok";
  } catch (e) {
    assert.ok(e instanceof ProtocolError, String(e));
    return e.code;
  }
};

test("python float repr", () => {
  assert.equal(pyFloat(120), "120.0");
  assert.equal(pyFloat(12.5), "12.5");
  assert.equal(pyFloat(0.1 + 0.2), "0.30000000000000004");
  assert.equal(pyFloat(0.00001), "1e-05");
  assert.equal(pyFloat(0), "0.0");
});

test("canonical json is sorted, compact and ascii", () => {
  assert.equal(canonicalJson({ b: 1, a: "ж", c: [true, null] }), '{"a":"\\u0436","b":1,"c":[true,null]}');
  assert.equal(canonicalJson({ s: 60 }, new Set(["s"])), '{"s":60.0}');
  assert.throws(() => canonicalJson({ x: 1.5 }), ProtocolError);
});

function safetensors(tensors, { dtype = "F16", meta = null } = {}) {
  const header = {};
  let off = 0;
  for (const [name, shape] of tensors) {
    const n = 2 * shape.reduce((a, b) => a * b, 1);
    header[name] = { dtype, shape, data_offsets: [off, off + n] };
    off += n;
  }
  if (meta) header.__metadata__ = meta;
  const h = new TextEncoder().encode(JSON.stringify(header));
  const out = new Uint8Array(8 + h.length + off);
  new DataView(out.buffer).setBigUint64(0, BigInt(h.length), true);
  out.set(h, 8);
  return out;
}

const spec = { tensors: [{ name: "m.A", shape: [2, 4] }, { name: "m.B", shape: [4, 2] }] };

test("only well-formed fp16 safetensors of the spec pass", async () => {
  const good = safetensors([["m.A", [2, 4]], ["m.B", [4, 2]]]);
  assert.equal(await code(() => checkSafetensors(good, spec)), "ok");
  assert.equal(await code(() => checkSafetensors(safetensors([["m.A", [2, 4]]]), spec)), "spec_mismatch");
  assert.equal(await code(() => checkSafetensors(safetensors([["m.A", [2, 4]], ["m.B", [4, 2]]], { dtype: "F32" }), spec)), "spec_mismatch");
  assert.equal(await code(() => checkSafetensors(good.subarray(0, good.length - 2), spec)), "bad_payload");
  assert.equal(await code(() => checkSafetensors(new Uint8Array([0x80, 4, 0x7d, 0x71, 0, 0x2e, 0, 0, 0, 0]), spec)), "bad_payload");
  assert.equal(await code(() => checkSafetensors(new Uint8Array([0x50, 0x4b, 3, 4, 0, 0, 0, 0, 0]), spec)), "bad_payload");
});

test("task tokens: login, version, expiry, signature", async () => {
  const tok = await signClaims({ task_id: "t", login: "Alice", base_version: 3, seconds_max: 12.5, steps_max: 50,
                                 expires_at: 1000 }, "s".repeat(32));
  assert.equal((await verifyToken(tok, "s".repeat(32), { login: "alice", baseVersion: 3, now: 999 })).steps_max, 50);
  for (const [opts, secret] of [[{ login: "bob", baseVersion: 3, now: 999 }, "s".repeat(32)],
                                [{ login: "alice", baseVersion: 4, now: 999 }, "s".repeat(32)],
                                [{ login: "alice", baseVersion: 3, now: 1001 }, "s".repeat(32)],
                                [{ login: "alice", baseVersion: 3, now: 999 }, "x".repeat(32)]]) {
    assert.equal(await code(() => verifyToken(tok, secret, opts)), "bad_task");
  }
});

test("github user: account age and type", () => {
  const now = Date.parse("2026-10-14T00:00:00Z") / 1000;
  assert.equal(parseGithubUser({ login: "alice", id: 1, created_at: "2015-01-01T00:00:00Z" }, { now, minAgeDays: 30 }).login, "alice");
  assert.throws(() => parseGithubUser({ login: "new", id: 2, created_at: "2026-10-10T00:00:00Z" }, { now, minAgeDays: 30 }),
                (e) => e.code === "forbidden");
  assert.throws(() => parseGithubUser({ login: "org", id: 3, created_at: "2015-01-01T00:00:00Z", type: "Organization" },
                                      { now, minAgeDays: 30 }), (e) => e.code === "forbidden");
  assert.throws(() => parseGithubUser({ login: "bad login", id: 4, created_at: "x" }, { now, minAgeDays: 30 }),
                (e) => e.code === "unauthorized");
});

test("rate limit per day", () => {
  let t = rateCheck([], 100, 2, "x");
  t = rateCheck(t, 200, 2, "x");
  assert.throws(() => rateCheck(t, 300, 2, "x"), (e) => e.code === "rate_limited" && e.extra.retry_after === 86400 - 200);
  assert.deepEqual(rateCheck(t, 100 + 86401, 2, "x"), [200, 86501]);
});

test("pool shard, exclusions journal and picking", () => {
  const ch = "UC" + "a".repeat(22);
  const excluded = parseExclusions(`# id\tdate\n${ch}\t2026-10-14\n`);
  assert.deepEqual([...excluded], [ch]);
  const pool = parsePool([
    JSON.stringify({ video_id: "aaaaaaaaaaa", channel_id: ch, segments: [{ start: 1, end: 3, text: "раз" }] }),
    JSON.stringify({ video_id: "bbbbbbbbbbb", channel_id: "UCother", segments: [{ start: 1, end: 3, text: "два" },
      { start: 5, end: 40, text: "длинный" }] }),
    "not json", JSON.stringify({ video_id: "short", segments: [] }),
  ].join("\n"));
  assert.equal(pool.length, 2);
  const picked = pickVideos(pool, { given: new Set(), excluded, count: 5, segmentsPerVideo: 20 });
  assert.deepEqual(picked.map((v) => v.video_id), ["bbbbbbbbbbb"]);
  assert.equal(picked[0].segments.length, 1);
  assert.equal(pickVideos(pool, { given: new Set(["bbbbbbbbbbb"]), excluded, count: 5, segmentsPerVideo: 20 }).length, 0);
});
