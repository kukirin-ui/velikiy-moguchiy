// The Hugging Face Hub calls the Worker needs: read a file of a repo and commit several files at once. Large files
// go through LFS (preupload says which), exactly as huggingface_hub's create_commit does.
import { b64encode, hex, sha256 } from "./lib.js";

const HUB = "https://huggingface.co";
const prefix = (type) => (type === "model" ? "" : `${type}s/`);

export async function hubFile(repo, type, path, token) {
  const r = await fetch(`${HUB}/${prefix(type)}${repo}/resolve/main/${path}`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`Hub ${r.status} for ${path}`);
  return r.text();
}

async function hubJson(url, token, body, accept = "application/json") {
  const r = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: accept },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`Hub ${r.status} at ${new URL(url).pathname}`);
  return r.json();
}

// files: [{path, bytes}]
export async function hubCommit(repo, type, token, files, summary) {
  const pre = await hubJson(`${HUB}/api/${prefix(type)}${repo}/preupload/main`, token, {
    files: files.map((f) => ({ path: f.path, size: f.bytes.length, sample: b64encode(f.bytes.subarray(0, 512)) })),
  });
  const mode = new Map(pre.files.map((f) => [f.path, f.uploadMode]));
  const lines = [{ key: "header", value: { summary, description: "" } }];
  for (const f of files) {
    if (mode.get(f.path) === "lfs") {
      const oid = hex(await sha256(f.bytes));
      const batch = await hubJson(`${HUB}/${prefix(type)}${repo}.git/info/lfs/objects/batch`, token, {
        operation: "upload", transfers: ["basic"], hash_algo: "sha_256", ref: { name: "main" },
        objects: [{ oid, size: f.bytes.length }],
      }, "application/vnd.git-lfs+json");
      const obj = batch.objects[0];
      if (obj.error) throw new Error(`LFS ${obj.error.code}`);
      const up = obj.actions && obj.actions.upload;
      if (up) {
        const put = await fetch(up.href, { method: "PUT", headers: up.header || {}, body: f.bytes });
        if (!put.ok) throw new Error(`LFS upload ${put.status}`);
        const verify = obj.actions.verify;
        if (verify) {
          const v = await fetch(verify.href, {
            method: "POST",
            headers: { ...(verify.header || {}), Authorization: `Bearer ${token}`, "Content-Type": "application/vnd.git-lfs+json" },
            body: JSON.stringify({ oid, size: f.bytes.length }),
          });
          if (!v.ok) throw new Error(`LFS verify ${v.status}`);
        }
      }
      lines.push({ key: "lfsFile", value: { path: f.path, algo: "sha256", oid, size: f.bytes.length } });
    } else {
      lines.push({ key: "file", value: { path: f.path, content: b64encode(f.bytes), encoding: "base64" } });
    }
  }
  const r = await fetch(`${HUB}/api/${prefix(type)}${repo}/commit/main`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/x-ndjson" },
    body: lines.map((l) => JSON.stringify(l)).join("\n"),
  });
  if (!r.ok) throw new Error(`Hub commit ${r.status}`);
}
