// SNS -> alert forwarder.
//
// The default subscriber on the alerts SNS topic. It normalizes each alert
// (a CloudWatch alarm state-change or an AMP Alertmanager notification) into one
// shape, writes it as a JSON line to its own CloudWatch log group (a durable
// record of every alert), and, when a destination is configured, delivers it to
// Slack or a generic webhook.
//
// The SNS topic is the stable seam: change ALERT_DESTINATION and the webhook URL
// to swap destinations; the alarms and rules stay put. The webhook URL is read
// from Secrets Manager at runtime, so no secret lives in the code or the function
// config.
//
// The two sources deliver different payloads:
//   - CloudWatch alarms  -> JSON (AlarmName, NewStateValue, NewStateReason, ...).
//   - AMP Alertmanager   -> a compact, pipe-delimited line per alert that the
//     Alertmanager `message` template is configured to emit:
//        POWERSYNC_ALERT|status|severity|alertname|title|value|summary
//     (Alertmanager's own default template is an unstructured text blob, so we
//     override it to something parseable rather than parsing free text.)
//
// Env:
//   ALERT_DESTINATION       log | slack | webhook   (default: log)
//   ALERT_WEBHOOK_SECRET_ID Secrets Manager secret name or ARN whose value is the
//                           webhook URL (required for slack/webhook; the log
//                           destination ignores it)
//   ALERT_DASHBOARD_URL     Grafana dashboard URL used as the "View in Grafana"
//                           link for metric (AMP) alerts (optional)
//
// Dependencies: Node built-ins + the AWS SDK v3 that ships in the Lambda runtime
// (no bundling / build step — archive_file zips this file as-is).

import https from "node:https";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

// Explicit, human-facing titles for the infra alarms. Falls back to a derived
// "PowerSync <name>" for anything not listed.
const CW_TITLES = {
  "powersync-api-no-healthy-hosts": "PowerSync API — no healthy hosts",
  "powersync-api-target-5xx": "PowerSync API — 5xx errors",
  "powersync-api-cpu-high": "PowerSync API — high CPU",
  "powersync-compaction-launch-failed": "PowerSync — compaction failed to launch",
  "powersync-opensearch-cluster-red": "PowerSync OpenSearch — cluster red",
  "powersync-opensearch-low-storage": "PowerSync OpenSearch — low storage",
};

const STATE = { FIRING: "FIRING", RESOLVED: "RESOLVED", NODATA: "NO DATA" };

const COLORS = { critical: "#E01E5A", warning: "#ECB22E", resolved: "#2EB67D", nodata: "#717274" };
const EMOJI = { critical: "🔴", warning: "🟡", resolved: "✅", nodata: "⚪" };

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function fmtWhen(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()} ${hh}:${mm} UTC`;
}

function fmtNumber(raw) {
  if (raw == null || raw === "") return null;
  // Values may carry a unit suffix (e.g. "312s"); round only the numeric part.
  const m = String(raw).match(/^(-?\d+(?:\.\d+)?)(.*)$/);
  if (!m) return String(raw);
  return `${+parseFloat(m[1]).toFixed(2)}${m[2]}`;
}

function cwTitle(name) {
  return CW_TITLES[name] || `PowerSync ${String(name).replace(/^powersync-/, "").replace(/-/g, " ")}`;
}

// Collapse the two SNS payload shapes into a flat list of normalized alerts:
//   { title, state, severity, summary, value, metric, source, when, link }
function normalize(sns) {
  const raw = sns.Message || "";
  const region = process.env.AWS_REGION || "us-east-1";
  const dashboard = process.env.ALERT_DASHBOARD_URL || "";

  // CloudWatch alarm state-change (JSON).
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    msg = null;
  }
  if (msg && msg.AlarmName && msg.NewStateValue) {
    const nv = msg.NewStateValue; // ALARM | OK | INSUFFICIENT_DATA
    const state = nv === "ALARM" ? STATE.FIRING : nv === "OK" ? STATE.RESOLVED : STATE.NODATA;
    const valMatch = (msg.NewStateReason || "").match(/\[(-?[\d.]+)\s*\(/);
    return [
      {
        title: cwTitle(msg.AlarmName),
        state,
        severity: state === STATE.RESOLVED ? "resolved" : nv === "ALARM" ? "critical" : "warning",
        summary: msg.AlarmDescription || "",
        value: valMatch ? fmtNumber(valMatch[1]) : null,
        metric: msg.Trigger?.MetricName || null,
        source: "AWS infrastructure (CloudWatch)",
        when: msg.StateChangeTime || sns.Timestamp || null,
        link: `https://${region}.console.aws.amazon.com/cloudwatch/home?region=${region}#alarmsV2:alarm/${encodeURIComponent(
          msg.AlarmName,
        )}`,
        linkLabel: "View in CloudWatch",
      },
    ];
  }

  // AMP Alertmanager (our custom pipe-delimited template).
  if (raw.includes("POWERSYNC_ALERT|")) {
    return raw
      .split("\n")
      .filter((l) => l.startsWith("POWERSYNC_ALERT|"))
      .map((line) => {
        const p = line.split("|");
        const status = p[1] || "firing";
        const severity = p[2] || "warning";
        const alertname = p[3] || "PowerSync alert";
        const title = p[4] || alertname;
        const value = p[5] || null;
        const summary = p.slice(6).join("|"); // summary is last; tolerate stray pipes
        const state = status === "resolved" ? STATE.RESOLVED : STATE.FIRING;
        return {
          title,
          state,
          severity: state === STATE.RESOLVED ? "resolved" : severity,
          summary,
          value: fmtNumber(value),
          metric: null,
          source: "PowerSync metrics (AMP)",
          when: sns.Timestamp || null,
          link: dashboard || null,
          linkLabel: dashboard ? "View in Grafana" : null,
        };
      });
  }

  // Unrecognized payload: forward it verbatim rather than dropping it.
  return [
    {
      title: sns.Subject || "PowerSync alert",
      state: STATE.FIRING,
      severity: "warning",
      summary: raw,
      value: null,
      metric: null,
      source: "unknown",
      when: sns.Timestamp || null,
      link: null,
      linkLabel: null,
    },
  ];
}

function severityKey(m) {
  if (m.state === STATE.RESOLVED) return "resolved";
  if (m.state === STATE.NODATA) return "nodata";
  return m.severity === "critical" ? "critical" : "warning";
}

function slackBody(m) {
  const key = severityKey(m);
  const contextBits = [
    m.severity && m.severity !== "resolved" ? m.severity : null,
    m.source,
    m.value != null ? `${m.metric ? `${m.metric}: ` : ""}${m.value}` : null,
    fmtWhen(m.when) || null,
  ].filter(Boolean);

  const blocks = [
    { type: "section", text: { type: "mrkdwn", text: `${EMOJI[key]}  *${m.title}*  ·  ${m.state}` } },
  ];
  if (m.summary) blocks.push({ type: "section", text: { type: "mrkdwn", text: m.summary } });
  if (contextBits.length) {
    blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: contextBits.join("  ·  ") }] });
  }
  if (m.link) {
    blocks.push({
      type: "actions",
      elements: [{ type: "button", text: { type: "plain_text", text: m.linkLabel || "Open" }, url: m.link }],
    });
  }

  return { attachments: [{ color: COLORS[key], blocks }] };
}

function postJson(url, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = JSON.stringify(body);
    const req = https.request(
      {
        hostname: u.hostname,
        path: `${u.pathname}${u.search}`,
        method: "POST",
        headers: { "content-type": "application/json", "content-length": Buffer.byteLength(data) },
      },
      (res) => {
        let out = "";
        res.on("data", (c) => (out += c));
        res.on("end", () =>
          res.statusCode >= 200 && res.statusCode < 300
            ? resolve(out)
            : reject(new Error(`HTTP ${res.statusCode}: ${out}`)),
        );
      },
    );
    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

// Fetch (and cache across warm invocations) the webhook URL from Secrets Manager.
let cachedUrl;
async function webhookUrl() {
  if (cachedUrl !== undefined) return cachedUrl;
  const secretId = process.env.ALERT_WEBHOOK_SECRET_ID;
  if (!secretId) {
    cachedUrl = null;
    return null;
  }
  const sm = new SecretsManagerClient({});
  const res = await sm.send(new GetSecretValueCommand({ SecretId: secretId }));
  cachedUrl = (res.SecretString || "").trim() || null;
  return cachedUrl;
}

export const handler = async (event) => {
  const dest = (process.env.ALERT_DESTINATION || "log").toLowerCase();

  const alerts = [];
  for (const rec of event.Records || []) {
    const sns = rec.Sns || {};
    for (const m of normalize(sns)) {
      // Durable record — always, regardless of destination.
      console.log(JSON.stringify({ level: m.state === STATE.RESOLVED ? "info" : "warn", source: "powersync-alerts", ...m }));
      alerts.push(m);
    }
  }

  if (dest === "log" || alerts.length === 0) return;

  const url = await webhookUrl();
  if (!url) {
    console.warn(`ALERT_DESTINATION=${dest} but no webhook URL configured; logged only`);
    return;
  }

  for (const m of alerts) {
    const body = dest === "slack" ? slackBody(m) : m;
    try {
      await postJson(url, body);
    } catch (e) {
      console.error(`forward to ${dest} failed for "${m.title}": ${e.message}`);
    }
  }
};

// Exposed for local unit tests; unused by the Lambda runtime (handler only).
export const _internals = { normalize, slackBody };
