// Intake server of «Помочь обучить» on Cloudflare Workers: the same API as federated/space/app.py for /v1/config,
// /v1/task and /v1/updates. It keeps nothing but rate-limit counters (KV binding LIMITS): updates are committed to
// the private Hugging Face inbox dataset (federated/hub/inbox.py layout), the aggregator in GitHub Actions does the
// rest. Adapter versions are not served here: the client reads them from the public model repo.
//
// Secrets: HF_TOKEN (write to the inbox dataset), FL_TASK_SECRET. Variables: see wrangler.toml.
import defaults from "./defaults.json" with { type: "json" };
import { hubCommit, hubFile } from "./hf.js";
import {
  HTTP_STATUS, ProtocolError, bearerToken, checkSafetensors, hex, parseExclusions, parseGithubUser, parsePool,
  pickVideos, rateCheck, sha256, signClaims, verifyContribution, verifyManifest, verifyToken,
} from "./lib.js";

const DAY = 86400;
const cache = { index: null, indexAt: 0, excl: null, exclAt: 0, shards: null, shardsAt: 0, users: new Map() };

const repoOf = (spec) => String(spec || "").replace(/^hf:/, "");

function settings(env) {
  const num = (k, d) => (env[k] ? Number(env[k]) : d);
  return {
    inbox: repoOf(env.FL_INBOX), models: repoOf(env.FL_MODELS), clientId: env.FL_GITHUB_CLIENT_ID || "",
    shards: env.FL_POOL_SHARDS || "pool/shards", exclusionsUrl: env.FL_EXCLUSIONS_URL || defaults.exclusions_url,
    minAgeDays: num("FL_MIN_ACCOUNT_AGE_DAYS", 30), maxUpdates: num("FL_MAX_UPDATES_PER_DAY", 2),
    maxTasks: num("FL_MAX_TASKS_PER_DAY", 3), videosPerTask: num("FL_VIDEOS_PER_TASK", 8), segmentsPerVideo: 20,
    ttlHours: 72, banned: new Set(String(env.FL_BANNED_LOGINS || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean)),
    training: { ...defaults.training, ...(env.FL_TRAINING_JSON ? JSON.parse(env.FL_TRAINING_JSON) : {}) },
  };
}

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8", ...headers } });
}

function errorResponse(e) {
  if (e instanceof ProtocolError) {
    const headers = e.extra.retry_after ? { "Retry-After": String(e.extra.retry_after) } : {};
    const { retry_after: _r, ...extra } = e.extra;
    return json({ error: e.code, message: e.detail, ...extra }, HTTP_STATUS[e.code] || 400, headers);
  }
  console.error(e && e.stack ? e.stack : String(e));
  return json({ error: "server_error", message: "внутренняя ошибка сервера" }, 500);
}

async function kvJson(env, key, dflt) {
  const v = await env.LIMITS.get(key);
  return v === null ? dflt : JSON.parse(v);
}

async function registry(s, now) {
  if (!cache.index || now - cache.indexAt > 60) {
    const text = await hubFile(s.models, "model", "index.json", null);
    cache.index = text ? JSON.parse(text) : { current: null, versions: [] };
    cache.indexAt = now;
  }
  if (cache.index.spec_hash && cache.index.spec_hash !== defaults.spec.spec_hash) {
    throw new ProtocolError("unavailable", "реестр адаптера для другой спецификации");
  }
  if (!cache.index.current) throw new ProtocolError("unavailable", "общий адаптер ещё не опубликован");
  return cache.index;
}

async function githubUser(request, env, s, now) {
  const token = bearerToken(request.headers.get("authorization"));
  const key = hex(await sha256(new TextEncoder().encode(token)));
  let hit = cache.users.get(key);
  if (!hit || now - hit.at > 600) {
    const r = await fetch("https://api.github.com/user", {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "User-Agent": "velikiy-moguchiy-train" },
    });
    if (r.status === 401) throw new ProtocolError("unauthorized", "токен GitHub недействителен или отозван: войдите заново");
    if (!r.ok) throw new ProtocolError("unavailable", `GitHub ответил ${r.status}`);
    hit = { at: now, body: await r.json() };
    cache.users.set(key, hit);
    if (cache.users.size > 5000) cache.users.clear();
  }
  const user = parseGithubUser(hit.body, { now, minAgeDays: s.minAgeDays });
  if (s.banned.has(user.login.toLowerCase())) throw new ProtocolError("banned", "участие для этого аккаунта закрыто");
  return user;
}

async function exclusions(s, now) {
  if (!cache.excl || now - cache.exclAt > 900) {
    const r = await fetch(s.exclusionsUrl);
    // fail closed: without the journal no task goes out
    if (r.status !== 404 && !r.ok) throw new ProtocolError("unavailable", "журнал исключений недоступен");
    cache.excl = r.status === 404 ? new Set() : parseExclusions(await r.text());
    cache.exclAt = now;
  }
  return cache.excl;
}

async function task(request, env, s, now) {
  const user = await githubUser(request, env, s, now);
  const idx = await registry(s, now);
  const excluded = await exclusions(s, now);
  const rlKey = `rl:task:${user.login.toLowerCase()}`;
  const times = rateCheck(await kvJson(env, rlKey, []), now, s.maxTasks, "заданий");
  if (!cache.shards || now - cache.shardsAt > 3600) {
    const text = await hubFile(s.inbox, "dataset", `${s.shards}/index.json`, env.HF_TOKEN);
    cache.shards = text ? JSON.parse(text).shards : 0;
    cache.shardsAt = now;
  }
  if (!cache.shards) throw new ProtocolError("unavailable", "пул роликов ещё не загружен");
  const givenKey = `given:${user.login.toLowerCase()}`;
  const given = new Set(await kvJson(env, givenKey, []));
  let videos = [];
  for (let attempt = 0; attempt < 4 && videos.length < s.videosPerTask; attempt++) {
    const n = Math.floor(Math.random() * cache.shards);
    const pool = parsePool(await hubFile(s.inbox, "dataset", `${s.shards}/${String(n).padStart(5, "0")}.jsonl`, env.HF_TOKEN));
    const taken = new Set([...given, ...videos.map((v) => v.video_id)]);
    videos = videos.concat(pickVideos(pool, { given: taken, excluded, count: s.videosPerTask - videos.length,
                                              segmentsPerVideo: s.segmentsPerVideo }));
  }
  if (!videos.length) throw new ProtocolError("unavailable", "новых роликов для вас сейчас нет, загляните позже");
  const seconds = Math.round(videos.reduce((a, v) => a + v.segments.reduce((b, x) => b + x.end - x.start, 0), 0) * 10) / 10;
  const claims = { task_id: crypto.randomUUID().replace(/-/g, ""), login: user.login, base_version: idx.current,
                   seconds_max: seconds, steps_max: Math.trunc(s.training.steps), expires_at: now + s.ttlHours * 3600,
                   segments: videos.reduce((a, v) => a + v.segments.length, 0) };
  await env.LIMITS.put(rlKey, JSON.stringify(times), { expirationTtl: 2 * DAY });
  await env.LIMITS.put(givenKey, JSON.stringify([...given, ...videos.map((v) => v.video_id)].slice(-2000)), { expirationTtl: 180 * DAY });
  return json({ task_id: claims.task_id, login: user.login, base_version: idx.current, issued_at: now,
                expires_at: claims.expires_at, seconds_max: seconds, videos, training: s.training, assets: defaults.assets,
                token: await signClaims(claims, env.FL_TASK_SECRET) });
}

async function updates(request, env, s, now) {
  const spec = defaults.spec;
  const cl = request.headers.get("content-length");
  if (cl === null) throw new ProtocolError("length_required", "нужен Content-Length");
  const limit = spec.max_payload_bytes + 8 * 1024 + 4 * 1024 + 16 * 1024;
  if (!/^\d+$/.test(cl) || Number(cl) > limit) throw new ProtocolError("too_large", `тело запроса больше ${limit} байт`);
  const user = await githubUser(request, env, s, now);
  let form;
  try {
    form = await request.formData();
  } catch {
    throw new ProtocolError("bad_schema", "тело не multipart/form-data");
  }
  const names = [...form.keys()].sort();
  if (names.join() !== "contribution,manifest,payload") {
    throw new ProtocolError("bad_schema", "нужны ровно три файловые части: manifest, payload, contribution");
  }
  const part = async (k) => {
    const v = form.get(k);
    if (typeof v === "string") throw new ProtocolError("bad_schema", `${k}: нужна файловая часть`);
    return new Uint8Array(await v.arrayBuffer());
  };
  const [envelope, payload, contribution] = [await part("manifest"), await part("payload"), await part("contribution")];
  if (payload.length > spec.max_payload_bytes) throw new ProtocolError("too_large", "нагрузка больше дельты адаптера");
  const m = await verifyManifest(envelope);
  if (m.payload_bytes !== payload.length || m.payload_sha256 !== hex(await sha256(payload))) {
    throw new ProtocolError("bad_payload", "размер или SHA-256 нагрузки не совпали с манифестом");
  }
  if (m.spec_id !== spec.spec_id || m.spec_hash !== spec.spec_hash) {
    throw new ProtocolError("spec_mismatch", "спецификация адаптера в манифесте не совпала с серверной");
  }
  checkSafetensors(payload, spec);
  const c = await verifyContribution(contribution, m);
  const idx = await registry(s, now);
  if (m.base_version !== idx.current) {
    const known = (idx.versions || []).some((v) => v.version === m.base_version);
    throw new ProtocolError(known ? "stale_base" : "unknown_base", `база v${m.base_version} устарела, актуальна v${idx.current}`,
                            { latest_version: idx.current });
  }
  const claims = await verifyToken(c.task_token, env.FL_TASK_SECRET, { login: user.login, baseVersion: idx.current, now });
  if (m.num_examples > claims.segments) {
    throw new ProtocolError("bad_task", `примеров ${m.num_examples}, а в задании ${claims.segments} отрезков`);
  }
  const login = user.login.toLowerCase();
  const sha16 = m.payload_sha256.slice(0, 16);
  const onceKey = `upd:${login}:${idx.current}`;
  const prev = await kvJson(env, onceKey, null);
  if (prev) {
    if (prev.sha16 !== sha16) throw new ProtocolError("conflict", "на эту версию адаптера от вас уже принято другое обновление");
    return json({ status: "duplicate", update_id: prev.prefix, base_version: idx.current, update_norm: null, pending_in_round: null });
  }
  const rlKey = `rl:update:${login}`;
  const times = rateCheck(await kvJson(env, rlKey, []), now, s.maxUpdates, "обновлений");
  const prefix = `pending/${user.login}/v${String(idx.current).padStart(6, "0")}-${String(now).padStart(10, "0")}-${sha16}/`;
  const meta = { protocol: 2, login: user.login, github_id: user.id, client_id: m.client_id, received_at: now,
                 base_version: idx.current, norm: null, num_examples: m.num_examples,
                 task: { task_id: claims.task_id, seconds_max: claims.seconds_max, steps_max: claims.steps_max,
                         segments: claims.segments } };
  await hubCommit(s.inbox, "dataset", env.HF_TOKEN, [
    { path: prefix + "manifest.json", bytes: envelope },
    { path: prefix + "payload.safetensors", bytes: payload },
    { path: prefix + "contribution.json", bytes: contribution },
    { path: prefix + "meta.json", bytes: new TextEncoder().encode(JSON.stringify(meta)) },
  ], `update from ${user.login} on v${idx.current}`);
  await env.LIMITS.put(onceKey, JSON.stringify({ sha16, prefix }), { expirationTtl: 60 * DAY });
  await env.LIMITS.put(rlKey, JSON.stringify(times), { expirationTtl: 2 * DAY });
  return json({ status: "accepted", update_id: prefix, base_version: idx.current, update_norm: null, pending_in_round: null });
}

export default {
  async fetch(request, env) {
    const s = settings(env);
    const now = Math.floor(Date.now() / 1000);
    const { pathname } = new URL(request.url);
    try {
      if (request.method === "GET" && pathname === "/v1/health") {
        let latest = null;
        try {
          latest = (await registry(s, now)).current;
        } catch {
          latest = null;
        }
        return json({ status: "ok", protocol: 2, latest_version: latest });
      }
      if (request.method === "GET" && pathname === "/v1/config") {
        return json({ protocol: 2, github_client_id: s.clientId, spec_id: defaults.spec.spec_id, spec_hash: defaults.spec.spec_hash,
                      max_updates_per_day: s.maxUpdates, max_tasks_per_day: s.maxTasks });
      }
      if (request.method === "GET" && pathname === "/v1/task") return await task(request, env, s, now);
      if (request.method === "POST" && pathname === "/v1/updates") return await updates(request, env, s, now);
      if (pathname.startsWith("/v1/model/")) {
        throw new ProtocolError("not_found", "версии адаптера раздаёт репозиторий модели на Hugging Face");
      }
      if (request.method === "GET" && pathname === "/") {
        return new Response("«Великий & Могучий»: сервер приёма обновлений весов. Код: https://github.com/zigansh1n/velikiy-moguchiy/tree/main/federated\n",
                            { headers: { "Content-Type": "text/plain; charset=utf-8" } });
      }
      throw new ProtocolError("not_found", "нет такого адреса");
    } catch (e) {
      return errorResponse(e);
    }
  },
};
