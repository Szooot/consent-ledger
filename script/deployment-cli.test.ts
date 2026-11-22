import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { networkConfigs, runProcess, writeAtomicFile } from "./deployment.ts";
import { verifyContractArgs } from "./deployment-sources.ts";

const script = fileURLToPath(new URL("./deployment.ts", import.meta.url));

function temporaryDirectory(): string {
  return mkdtempSync(join(tmpdir(), "consent-ledger-deployment-cli-"));
}

function executable(directory: string, name: string, body: string): string {
  const path = join(directory, name);
  writeFileSync(path, `#!${process.execPath}\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
}

function fakeCast(directory: string, chainId: string): string {
  return executable(directory, "cast", `if (process.argv[2] === "chain-id") console.log(${JSON.stringify(chainId)});`);
}

function environment(directory: string): NodeJS.ProcessEnv {
  return {
    DEPLOYMENTS_ROOT: join(directory, "deployments"),
    PENDING_ROOT: join(directory, "pending"),
    RPC_SEPOLIA: "http://sepolia.example",
    PRIVATE_KEY_SEPOLIA: "sepolia-key",
    LOGGER_ADDR_SEPOLIA: `0x${"5".repeat(40)}`,
    RPC_MAINNET: "http://mainnet.example",
    PRIVATE_KEY_MAINNET: "mainnet-key",
    LOGGER_ADDR_MAINNET: `0x${"5".repeat(40)}`,
    ETHERSCAN_API_KEY: "etherscan-key",
  };
}

function run(args: readonly string[], env: NodeJS.ProcessEnv = {}) {
  const base = { ...process.env };
  for (const name of Object.keys(base)) {
    if (/^(RPC|PRIVATE_KEY|LOGGER_ADDR)_/.test(name) || name === "ETHERSCAN_API_KEY" || name === "CONFIRM_MAINNET") {
      delete base[name];
    }
  }
  return spawnSync(process.execPath, [script, ...args], { encoding: "utf8", env: { ...base, ...env } });
}

test("rejects invalid command lines", () => {
  assert.match(run([]).stderr, /Usage: deployment.ts/);
  assert.match(run(["upgrade", "sepolia"]).stderr, /unsupported command/);
  assert.match(run(["deploy", "calibnet"]).stderr, /unsupported network/);
  assert.match(run(["deploy", "sepolia", "--force"]).stderr, /unsupported deploy arguments/);
  assert.match(run(["check-live", "sepolia", "extra"]).stderr, /does not accept arguments/);
});

test("requires the deployment inputs of the network", () => {
  const directory = temporaryDirectory();
  try {
    const env = environment(directory);
    delete env.LOGGER_ADDR_SEPOLIA;
    assert.match(run(["deploy", "sepolia"], env).stderr, /LOGGER_ADDR_SEPOLIA/);
    assert.match(
      run(["deploy", "sepolia"], { ...environment(directory), LOGGER_ADDR_SEPOLIA: `0x${"0".repeat(40)}` }).stderr,
      /must be a non-zero address/,
    );
    const noKey = environment(directory);
    delete noKey.PRIVATE_KEY_SEPOLIA;
    assert.match(run(["deploy", "sepolia"], noKey).stderr, /PRIVATE_KEY_SEPOLIA/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("refuses an RPC endpoint of another chain", () => {
  const directory = temporaryDirectory();
  try {
    const result = run(["deploy", "sepolia"], { ...environment(directory), CAST_BIN: fakeCast(directory, "1") });
    assert.match(result.stderr, /sepolia RPC chain ID must be 11155111, got 1/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("requires explicit confirmation on mainnet", () => {
  const directory = temporaryDirectory();
  try {
    const result = run(["deploy", "mainnet"], { ...environment(directory), CAST_BIN: fakeCast(directory, "1") });
    assert.match(result.stderr, /CONFIRM_MAINNET=yes/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("requires an Etherscan key on networks with source verification", () => {
  const directory = temporaryDirectory();
  try {
    const env: NodeJS.ProcessEnv = { ...environment(directory), CAST_BIN: fakeCast(directory, "11155111") };
    delete env.ETHERSCAN_API_KEY;
    assert.match(run(["deploy", "sepolia"], env).stderr, /ETHERSCAN_API_KEY/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("refuses to deploy uncommitted sources to a public network", () => {
  const directory = temporaryDirectory();
  try {
    const git = executable(directory, "git", 'console.log(" M src/UsageLog.sol");');
    const result = run(["deploy", "sepolia"], {
      ...environment(directory),
      CAST_BIN: fakeCast(directory, "11155111"),
      GIT_BIN: git,
    });
    assert.match(result.stderr, /deployment source is dirty/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("refuses to replace an existing deployment without --fresh", () => {
  const directory = temporaryDirectory();
  try {
    const env = { ...environment(directory), CAST_BIN: fakeCast(directory, "11155111"), GIT_BIN: executable(directory, "git", "") };
    writeAtomicFile(join(directory, "deployments", "sepolia", "latest.json"), "{}\n");
    assert.match(run(["deploy", "sepolia"], env).stderr, /already exists; pass --fresh/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("refuses to start while another deployment is pending", () => {
  const directory = temporaryDirectory();
  try {
    const env = { ...environment(directory), CAST_BIN: fakeCast(directory, "11155111"), GIT_BIN: executable(directory, "git", "") };
    writeAtomicFile(join(directory, "pending", "sepolia", "pending-deploy.json"), '{"status":"pending"}\n');
    assert.match(run(["deploy", "sepolia"], env).stderr, /just finalize-deploy sepolia/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("passes constructor arguments to source verification only when there are any", () => {
  const options = { chainId: 11155111, root: "/repo", runForge: async () => {} };
  const target = { label: "UsageLog", address: `0x${"3".repeat(40)}`, artifact: "src/UsageLog.sol:UsageLog" };
  const withArgs = verifyContractArgs({ ...target, constructorArgs: "0x1234" }, options);
  assert.deepEqual(withArgs.slice(0, 9), [
    "verify-contract",
    target.address,
    target.artifact,
    "--root",
    "/repo",
    "--chain",
    "11155111",
    "--verifier",
    "etherscan",
  ]);
  assert.deepEqual(withArgs.slice(-2), ["--constructor-args", "0x1234"]);
  assert.ok(!verifyContractArgs({ ...target, constructorArgs: "0x" }, options).includes("--constructor-args"));
});

test("reports a failing process with its stderr", async () => {
  await assert.rejects(runProcess(process.execPath, ["-e", "console.error('boom'); process.exit(3)"]), /code 3: boom/);
});

test("networks deploy with the expected admin delay", () => {
  assert.equal(networkConfigs.sepolia.adminDelay, 86_400);
  assert.equal(networkConfigs.mainnet.adminDelay, 432_000);
});
