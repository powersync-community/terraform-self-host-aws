// Temporary RDS access for local scripts: authorize the runner's current public IP on the RDS
// security group (5432), run the work, then revoke it. No hardcoded IP; anyone with AWS creds can
// run it. (You can also set var.admin_cidr in Terraform to keep a static rule instead — then these
// scripts still work and the temporary rule is just redundant.)
import {
  EC2Client,
  AuthorizeSecurityGroupIngressCommand,
  RevokeSecurityGroupIngressCommand,
} from "@aws-sdk/client-ec2";
import { tfOutput } from "../../lib/tf-outputs.ts";

async function publicIp(): Promise<string> {
  const res = await fetch("https://checkip.amazonaws.com");
  if (!res.ok) throw new Error(`Could not determine public IP: ${res.status}`);
  return (await res.text()).trim();
}

export async function withTempAccess<T>(fn: () => Promise<T>): Promise<T> {
  const region = tfOutput("aws_region");
  const groupId = tfOutput("db_security_group_id");
  const ec2 = new EC2Client({ region });
  const ip = await publicIp();
  const cidr = `${ip}/32`;

  const rule = {
    GroupId: groupId,
    IpPermissions: [
      {
        IpProtocol: "tcp",
        FromPort: 5432,
        ToPort: 5432,
        IpRanges: [{ CidrIp: cidr, Description: "example-client temporary seed access" }],
      },
    ],
  };

  try {
    await ec2.send(new AuthorizeSecurityGroupIngressCommand(rule));
    console.log(`🔓 temporarily allowlisted ${cidr} on ${groupId}`);
  } catch (e) {
    // Rule already present (e.g. covered by var.admin_cidr, or a leftover) — fine, carry on.
    if ((e as { name?: string }).name !== "InvalidPermission.Duplicate") throw e;
    console.log(`ℹ️  ${cidr} already allowed on ${groupId}`);
  }

  try {
    return await fn();
  } finally {
    try {
      await ec2.send(new RevokeSecurityGroupIngressCommand(rule));
      console.log(`🔒 removed temporary allowlist entry ${cidr}`);
    } catch (e) {
      console.warn(`⚠️  could not revoke ${cidr} on ${groupId}: ${(e as Error).message} — remove it manually if needed`);
    }
  }
}
