// Pure helpers of the intake Worker: no bindings, no network. Each mirrors a Python counterpart in federated/
// (named next to it), and test/lib.test.mjs plus tests/test_worker_compat.py keep the two in agreement.

export class ProtocolError extends Error {
  constructor(code, message = "", extra = {}) {
    super(`${code}: ${message}`);
    this.code = code;
    this.detail = message;
    this.extra = extra;
  }
}

// protocol/errors.py HTTP_STATUS
export const HTTP_STATUS = {
  bad_schema: 422, bad_signature: 401, bad_payload: 422, spec_mismatch: 422, too_large: 413, nonfinite: 422,
  norm_too_large: 422, stale_base: 409, unknown_base: 409, conflict: 409, rate_limited: 429, banned: 403,
  not_found: 404, length_required: 411, server_error: 500, unauthorized: 401, forbidden: 403, bad_task: 422,
  unavailable: 503,
};

const enc = new TextEncoder();
const dec = new TextDecoder();

export function b64encode(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function b64decode(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export const b64url = (bytes) => b64encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export const unb64url = (s) => b64decode(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));

export function hex(bytes) {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

// Python float repr for the values the protocol carries (finite, below 1e16)
export function pyFloat(x) {
  if (!Number.isFinite(x) || Math.abs(x) >= 1e16) throw new ProtocolError("bad_schema", "число вне допустимого");
  if (Number.isInteger(x)) return x.toFixed(1);
  if (x !== 0 && Math.abs(x) < 1e-4) {
    const [m, e] = x.toExponential().split("e");
    const sign = e[0] === "-" ? "-" : "+";
    return `${m}e${sign}${e.replace(/^[+-]/, "").padStart(2, "0")}`;
  }
  return String(x);
}

function pyString(s) {
  return JSON.stringify(s).replace(/[\u007f-￿]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
}

// protocol/canonical.py canonical_json: sorted keys, no spaces, ASCII only; keys in floatKeys print as Python floats
export function canonicalJson(value, floatKeys = new Set(), key = null) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (floatKeys.has(key)) return pyFloat(value);
    if (!Number.isInteger(value)) throw new ProtocolError("bad_schema", `${key}: ожидалось целое`);
    return String(value);
  }
  if (typeof value === "string") return pyString(value);
  if (Array.isArray(value)) return "[" + value.map((v) => canonicalJson(v, floatKeys, key)).join(",") + "]";
  const keys = Object.keys(value).sort();
  return "{" + keys.map((k) => pyString(k) + ":" + canonicalJson(value[k], floatKeys, k)).join(",") + "}";
}

const HEX32 = /^[0-9a-f]{32}$/;
const HEX64 = /^[0-9a-f]{64}$/;

function strictObject(obj, fields, what) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) throw new ProtocolError("bad_schema", `${what}: не объект`);
  const out = {};
  for (const k of Object.keys(obj)) if (!(k in fields)) throw new ProtocolError("bad_schema", `${what}: лишнее поле ${k}`);
  for (const [k, [check, dflt]] of Object.entries(fields)) {
    const v = k in obj ? obj[k] : dflt;
    if (v === undefined || !check(v)) throw new ProtocolError("bad_schema", `${what}: поле ${k}`);
    out[k] = v;
  }
  return out;
}

const isInt = (lo, hi) => (v) => Number.isInteger(v) && v >= lo && v <= hi;
const isStr = (re) => (v) => typeof v === "string" && re.test(v);

// protocol/schema.py UpdateManifest
export function parseManifest(obj) {
  return strictObject(obj, {
    schema_version: [(v) => v === 2, 2],
    client_id: [isStr(HEX32)],
    public_key: [isStr(/^[A-Za-z0-9+/]{43}=$/)],
    base_version: [isInt(1, Number.MAX_SAFE_INTEGER)],
    spec_id: [isStr(/^[\x20-\x7e]{1,64}$/)],
    spec_hash: [isStr(HEX64)],
    num_examples: [isInt(1, 1_000_000)],
    payload_sha256: [isStr(HEX64)],
    payload_bytes: [isInt(1, Number.MAX_SAFE_INTEGER)],
    payload_dtype: [(v) => v === "float16", "float16"],
  }, "манифест");
}

// protocol/contribution.py Contribution
export function parseContribution(obj) {
  return strictObject(obj, {
    schema_version: [(v) => v === 2, 2],
    client_id: [isStr(HEX32)],
    payload_sha256: [isStr(HEX64)],
    base_version: [isInt(1, Number.MAX_SAFE_INTEGER)],
    task_token: [(v) => typeof v === "string" && v.length >= 1 && v.length <= 2048 && /^[\x20-\x7e]+$/.test(v)],
    data_seconds: [(v) => typeof v === "number" && v >= 0 && v <= 86400],
    training_steps: [isInt(0, 100_000)],
    num_clips: [isInt(0, 100_000)],
    credit_public: [(v) => typeof v === "boolean", true],
  }, "сведения о вкладе");
}

export const UPDATE_DOMAIN = "velikiy-moguchiy-fl/update/v2\n";          // protocol/package.py
export const CONTRIBUTION_DOMAIN = "velikiy-moguchiy-fl/contribution/v2\n"; // protocol/contribution.py

function concat(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

export async function ed25519Verify(publicRaw, signature, data) {
  try {
    const key = await crypto.subtle.importKey("raw", publicRaw, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, data);
  } catch {
    return false;
  }
}

function parseSigned(bytes, inner, max, what) {
  if (bytes.length > max) throw new ProtocolError("too_large", `${what} больше ${max} байт`);
  let obj;
  try {
    obj = JSON.parse(dec.decode(bytes));
  } catch {
    throw new ProtocolError("bad_schema", `${what}: не JSON`);
  }
  if (!obj || typeof obj !== "object" || Object.keys(obj).sort().join() !== [inner, "signature"].sort().join()) {
    throw new ProtocolError("bad_schema", `${what}: нужны ровно поля ${inner} и signature`);
  }
  if (typeof obj.signature !== "string" || !/^[A-Za-z0-9+/]{86}==$/.test(obj.signature)) {
    throw new ProtocolError("bad_schema", `${what}: подпись`);
  }
  return obj;
}

// protocol/package.py parse_envelope + verify_signature_and_identity
export async function verifyManifest(bytes) {
  const obj = parseSigned(bytes, "manifest", 8 * 1024, "манифест");
  const m = parseManifest(obj.manifest);
  const pub = b64decode(m.public_key);
  if (hex((await sha256(pub)).slice(0, 16)) !== m.client_id) {
    throw new ProtocolError("bad_signature", "client_id не соответствует публичному ключу");
  }
  const data = concat(enc.encode(UPDATE_DOMAIN), enc.encode(canonicalJson(m)));
  if (!(await ed25519Verify(pub, b64decode(obj.signature), data))) throw new ProtocolError("bad_signature", "подпись не сходится");
  return m;
}

// protocol/contribution.py verify_contribution
export async function verifyContribution(bytes, manifest) {
  const obj = parseSigned(bytes, "contribution", 4 * 1024, "сведения о вкладе");
  const c = parseContribution(obj.contribution);
  if (c.client_id !== manifest.client_id || c.payload_sha256 !== manifest.payload_sha256 || c.base_version !== manifest.base_version) {
    throw new ProtocolError("bad_payload", "сведения о вкладе относятся к другому обновлению");
  }
  const data = concat(enc.encode(CONTRIBUTION_DOMAIN), enc.encode(canonicalJson(c, new Set(["data_seconds"]))));
  if (!(await ed25519Verify(b64decode(manifest.public_key), b64decode(obj.signature), data))) {
    throw new ProtocolError("bad_signature", "подпись сведений о вкладе не сходится");
  }
  return c;
}

// protocol/adapter_io.py check_safetensors_header + validate_against_spec (names, shapes, dtype, layout). Values are
// not decoded here: a full pass over 1.7 M halves does not fit the free plan's CPU budget, and the aggregator checks
// finiteness and the norm of every update anyway.
export function checkSafetensors(bytes, spec) {
  const head = bytes.subarray(0, 8);
  const starts = (sig) => sig.every((b, i) => bytes[i] === b);
  if (starts([0x50, 0x4b, 0x03, 0x04])) throw new ProtocolError("bad_payload", "принимается только safetensors, а это zip (torch.save)");
  if (starts([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59])) throw new ProtocolError("bad_payload", "принимается только safetensors, а это numpy");
  if (bytes[0] === 0x80 && bytes[8] !== 0x7b) throw new ProtocolError("bad_payload", "принимается только safetensors, а это pickle");
  if (bytes.length < 8) throw new ProtocolError("bad_payload", "файл короче заголовка safetensors");
  const hlen = Number(new DataView(head.buffer, head.byteOffset, 8).getBigUint64(0, true));
  if (hlen > 256 * 1024 || 8 + hlen > bytes.length) throw new ProtocolError("bad_payload", `некорректная длина заголовка: ${hlen}`);
  if (bytes[8] !== 0x7b) throw new ProtocolError("bad_payload", "заголовок safetensors не JSON");
  let header;
  try {
    header = JSON.parse(dec.decode(bytes.subarray(8, 8 + hlen)));
  } catch {
    throw new ProtocolError("bad_payload", "заголовок safetensors не разобран");
  }
  const names = Object.keys(header).filter((k) => k !== "__metadata__");
  const want = new Map(spec.tensors.map((t) => [t.name, t.shape]));
  if (names.length !== want.size || names.some((n) => !want.has(n))) throw new ProtocolError("spec_mismatch", "набор тензоров не совпал");
  const spans = [];
  for (const n of names) {
    const t = header[n];
    const shape = want.get(n);
    if (t.dtype !== "F16") throw new ProtocolError("spec_mismatch", `${n}: dtype ${t.dtype} вместо F16`);
    if (!Array.isArray(t.shape) || t.shape.join() !== shape.join()) throw new ProtocolError("spec_mismatch", `${n}: форма`);
    const [a, b] = t.data_offsets || [];
    if (!Number.isInteger(a) || !Number.isInteger(b) || b - a !== 2 * shape.reduce((x, y) => x * y, 1)) {
      throw new ProtocolError("bad_payload", `${n}: смещения данных`);
    }
    spans.push([a, b]);
  }
  spans.sort((x, y) => x[0] - y[0]);
  let pos = 0;
  for (const [a, b] of spans) {
    if (a !== pos) throw new ProtocolError("bad_payload", "данные тензоров не подряд");
    pos = b;
  }
  if (8 + hlen + pos !== bytes.length) throw new ProtocolError("bad_payload", "размер файла не совпал с заголовком");
}

// hub/tasks.py sign_claims / verify_token: HMAC-SHA256 over the exact body bytes
async function hmacKey(secret) {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function signClaims(claims, secret) {
  const body = enc.encode(canonicalJson({ t: claims.task_id, l: claims.login, b: claims.base_version, s: claims.seconds_max,
    k: claims.steps_max, e: claims.expires_at, n: claims.segments ?? 0 }, new Set(["s"])));
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), body));
  return b64url(body) + "." + b64url(sig);
}

export async function verifyToken(token, secret, { login, baseVersion, now }) {
  let claims = null;
  try {
    const [b, s] = token.split(".");
    const body = unb64url(b);
    if (await crypto.subtle.verify("HMAC", await hmacKey(secret), unb64url(s), body)) {
      const d = JSON.parse(dec.decode(body));
      claims = { task_id: String(d.t), login: String(d.l), base_version: d.b, seconds_max: d.s, steps_max: d.k, expires_at: d.e,
                 segments: Number.isInteger(d.n) ? d.n : 0 };
    }
  } catch {
    claims = null;
  }
  if (!claims) throw new ProtocolError("bad_task", "токен задания не разобран или подпись не сходится");
  if (claims.login.toLowerCase() !== login.toLowerCase()) throw new ProtocolError("bad_task", "задание выдано другому участнику");
  if (claims.base_version !== baseVersion) throw new ProtocolError("bad_task", "задание выдано на другую версию адаптера");
  if (now > claims.expires_at) throw new ProtocolError("bad_task", "срок задания истёк, возьмите новое");
  return claims;
}

// hub/github_auth.py parse_user + the account-age rule
export function parseGithubUser(body, { now, minAgeDays }) {
  const { login, id, created_at: created, type = "User" } = body || {};
  if (typeof login !== "string" || !/^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/.test(login) ||
      !Number.isInteger(id) || typeof created !== "string") {
    throw new ProtocolError("unauthorized", "GitHub вернул неожиданный ответ");
  }
  if (type !== "User") throw new ProtocolError("forbidden", "участвовать могут только личные аккаунты GitHub");
  if (now - Date.parse(created) / 1000 < minAgeDays * 86400) {
    throw new ProtocolError("forbidden", `аккаунту GitHub меньше ${minAgeDays} дней: так сервер защищается от подставных аккаунтов`);
  }
  return { login, id };
}

export function bearerToken(header) {
  if (!header) throw new ProtocolError("unauthorized", "нужен вход через GitHub (заголовок Authorization: Bearer <токен>)");
  const [scheme, ...rest] = header.split(" ");
  const token = rest.join(" ").trim();
  if (!["bearer", "token"].includes(scheme.toLowerCase()) || !token || token.length > 512 || !/^[\x21-\x7e]+$/.test(token)) {
    throw new ProtocolError("unauthorized", "заголовок Authorization не разобран");
  }
  return token;
}

// space/app.py LoginLimiter: timestamps of the last 24 h; returns the new list or throws rate_limited
export function rateCheck(times, now, perDay, what) {
  const recent = (times || []).filter((t) => now - t <= 86400).sort((a, b) => a - b);
  if (recent.length >= perDay) {
    throw new ProtocolError("rate_limited", `не больше ${perDay} ${what} за 24 часа`, { retry_after: Math.max(1, Math.ceil(recent[0] + 86400 - now)) });
  }
  return [...recent, now];
}

// hub/tasks.py parse_exclusions, the channels.tsv journal form (UC… <TAB> date)
export function parseExclusions(text) {
  const channels = new Set();
  for (const line of (text || "").split("\n")) {
    const first = line.split("#")[0].trim().split(/\s+/)[0];
    if (/^UC[A-Za-z0-9_-]{22}$/.test(first)) channels.add(first);
  }
  return channels;
}

// hub/tasks.py parse_pool, for one shard
export function parsePool(text) {
  const out = [];
  for (const line of (text || "").split("\n")) {
    if (!line.trim()) continue;
    let r;
    try {
      r = JSON.parse(line);
    } catch {
      continue;
    }
    if (!r || typeof r.video_id !== "string" || !/^[A-Za-z0-9_-]{11}$/.test(r.video_id) || !Array.isArray(r.segments)) continue;
    const segments = r.segments.filter((s) => s && typeof s.text === "string" && s.text.trim() && s.text.length <= 500 &&
      Number.isFinite(s.start) && Number.isFinite(s.end) && s.start >= 0 && s.end - s.start >= 0.5 && s.end - s.start <= 15)
      .map((s) => ({ start: s.start, end: s.end, text: s.text.trim() }));
    if (segments.length) out.push({ video_id: r.video_id, channel_id: String(r.channel_id || ""), segments });
  }
  return out;
}

export function pickVideos(pool, { given, excluded, count, segmentsPerVideo, random = Math.random }) {
  const cands = pool.filter((v) => !given.has(v.video_id) && !excluded.has(v.channel_id));
  for (let i = cands.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [cands[i], cands[j]] = [cands[j], cands[i]];
  }
  return cands.slice(0, count).map((v) => {
    let segs = v.segments;
    if (segs.length > segmentsPerVideo) {
      segs = [...segs].sort(() => random() - 0.5).slice(0, segmentsPerVideo).sort((a, b) => a.start - b.start);
    }
    return { video_id: v.video_id, segments: segs };
  });
}
