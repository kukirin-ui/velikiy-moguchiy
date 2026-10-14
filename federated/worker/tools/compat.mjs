// Run by tests/test_worker_compat.py: checks Python-made messages with the Worker's code and signs a task token
// for Python to verify. Prints one JSON object.
import { readFileSync } from "node:fs";
import { checkSafetensors, b64decode, ProtocolError, signClaims, verifyContribution, verifyManifest, verifyToken } from "../src/lib.js";

const fx = JSON.parse(readFileSync(process.argv[2], "utf8"));
const spec = JSON.parse(readFileSync(new URL("../src/defaults.json", import.meta.url), "utf8")).spec;
const out = {};
const code = async (f) => {
  try {
    await f();
    return "ok";
  } catch (e) {
    if (e instanceof ProtocolError) return e.code;
    throw e;
  }
};
const m = await verifyManifest(b64decode(fx.manifest));
out.manifest = m.client_id;
out.contribution = (await verifyContribution(b64decode(fx.contribution), m)).data_seconds;
out.payload = await code(() => checkSafetensors(b64decode(fx.payload), fx.spec || spec));
out.tampered_contribution = await code(() => verifyContribution(b64decode(fx.tampered_contribution), m));
out.pickle = await code(() => checkSafetensors(b64decode(fx.pickle), spec));
const py = await verifyToken(fx.token, fx.secret, { login: fx.login, baseVersion: fx.base, now: fx.now });
out.python_token = [py.task_id, py.segments];
out.js_token = await signClaims({ task_id: "js1", login: fx.login, base_version: fx.base, seconds_max: 120,
                                  steps_max: 50, expires_at: fx.now + 100, segments: 30 }, fx.secret);
console.log(JSON.stringify(out));
