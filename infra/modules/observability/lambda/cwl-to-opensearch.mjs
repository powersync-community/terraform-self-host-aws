// CloudWatch Logs subscription -> OpenSearch indexer.
//
// CloudWatch Logs invokes this (async) with a gzipped batch of log events. We
// decompress, turn each event into one document (parsing the message as JSON when
// it is JSON, so fields like level/logger become searchable), and bulk-index to
// OpenSearch with SigV4 auth (this Lambda's IAM role is mapped to a write role in
// OpenSearch FGAC). Daily indices: <prefix>-YYYY.MM.DD.
//
// Transport/auth failures throw, so CloudWatch Logs' async retries kick in and a
// poison batch lands in the SQS DLQ. Per-document bulk errors are logged (not
// thrown) so one bad doc doesn't force the whole batch to reprocess.
//
// Zero dependencies: only Node runtime built-ins + the creds Lambda injects as env.

import { gunzipSync } from "node:zlib";
import { createHash, createHmac } from "node:crypto";
import https from "node:https";

const ENDPOINT = process.env.OPENSEARCH_ENDPOINT; // host only, no scheme
const INDEX_PREFIX = process.env.INDEX_PREFIX || "powersync-logs";
const REGION = process.env.AWS_REGION;
const SERVICE = "es";

const sha256hex = (data) => createHash("sha256").update(data, "utf8").digest("hex");
const hmac = (key, data) => createHmac("sha256", key).update(data, "utf8").digest();

function signingKey(secret, dateStamp) {
  const kDate = hmac("AWS4" + secret, dateStamp);
  const kRegion = hmac(kDate, REGION);
  const kService = hmac(kRegion, SERVICE);
  return hmac(kService, "aws4_request");
}

// Minimal SigV4 for a POST to the OpenSearch _bulk endpoint.
function signedHeaders(method, path, body) {
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, ""); // YYYYMMDDTHHMMSSZ
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256hex(body);

  const headers = {
    host: ENDPOINT,
    "x-amz-content-sha256": payloadHash,
    "x-amz-date": amzDate,
  };
  if (process.env.AWS_SESSION_TOKEN) headers["x-amz-security-token"] = process.env.AWS_SESSION_TOKEN;

  const keys = Object.keys(headers).sort();
  const canonicalHeaders = keys.map((k) => `${k}:${headers[k]}\n`).join("");
  const signedHeadersStr = keys.join(";");
  const canonicalRequest = [method, path, "", canonicalHeaders, signedHeadersStr, payloadHash].join("\n");
  const scope = `${dateStamp}/${REGION}/${SERVICE}/aws4_request`;
  const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256hex(canonicalRequest)].join("\n");
  const signature = createHmac("sha256", signingKey(process.env.AWS_SECRET_ACCESS_KEY, dateStamp))
    .update(stringToSign, "utf8")
    .digest("hex");

  headers["Authorization"] =
    `AWS4-HMAC-SHA256 Credential=${process.env.AWS_ACCESS_KEY_ID}/${scope}, ` +
    `SignedHeaders=${signedHeadersStr}, Signature=${signature}`;
  headers["content-type"] = "application/x-ndjson";
  return headers;
}

function post(path, body) {
  const headers = signedHeaders("POST", path, body);
  return new Promise((resolve, reject) => {
    const req = https.request({ host: ENDPOINT, path, method: "POST", headers }, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

export const handler = async (event) => {
  const payload = JSON.parse(gunzipSync(Buffer.from(event.awslogs.data, "base64")).toString("utf8"));
  if (payload.messageType === "CONTROL_MESSAGE") return;

  const lines = [];
  for (const e of payload.logEvents || []) {
    const when = new Date(e.timestamp);
    const ymd = when.toISOString().slice(0, 10).replace(/-/g, ".");
    const doc = {
      "@timestamp": when.toISOString(),
      log_group: payload.logGroup,
      log_stream: payload.logStream,
      id: e.id,
    };
    let parsed = null;
    try {
      parsed = JSON.parse(e.message);
    } catch {
      parsed = null;
    }
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      Object.assign(doc, parsed);
      doc["@timestamp"] = when.toISOString(); // keep CWL event time as the time field
      if (doc.message === undefined) doc.message = e.message;
    } else {
      doc.message = e.message;
    }
    lines.push(JSON.stringify({ index: { _index: `${INDEX_PREFIX}-${ymd}` } }));
    lines.push(JSON.stringify(doc));
  }
  if (lines.length === 0) return;

  const { status, body } = await post("/_bulk", lines.join("\n") + "\n");
  if (status >= 300) throw new Error(`OpenSearch _bulk HTTP ${status}: ${body.slice(0, 500)}`);

  const result = JSON.parse(body);
  if (result.errors) {
    const failures = (result.items || []).filter((it) => it.index?.error).map((it) => it.index.error);
    console.warn(
      `${failures.length}/${(result.items || []).length} docs failed; first: ` +
        JSON.stringify(failures[0] || {}).slice(0, 300),
    );
  }
};
