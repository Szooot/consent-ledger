import assert from "node:assert/strict";
import { test } from "node:test";
import {
  detectRuntimeHardfork,
  extractBroadcastTransactionHashes,
  loadTransactionReceipts,
  verifyLiveDeployment,
  waitForFinality,
  type CommandRunner,
} from "./deployment-chain.ts";
import { parseDeploymentManifest, type DeploymentTransaction } from "./deployment-state.ts";

const rpcUrl = "http://rpc.example";
const registry = `0x${"1".repeat(40)}`;
const manager = `0x${"2".repeat(40)}`;
const usageLog = `0x${"3".repeat(40)}`;
const admin = `0x${"4".repeat(40)}`;
const logger = `0x${"5".repeat(40)}`;
const codeHash = `0x${"c".repeat(64)}`;
const blockHash = `0x${"d".repeat(64)}`;
const loggerRole = `0x${"e".repeat(64)}`;
const adminRole = `0x${"0".repeat(64)}`;

function transactionHash(index: number): string {
  return `0x${index.toString(16).padStart(64, "0")}`;
}

function receipt(index: number, blockNumber: number): DeploymentTransaction {
  return { hash: transactionHash(index), status: 1, blockNumber, blockHash, contractAddress: registry };
}

function manifest() {
  const contract = (artifact: string, address: string) => ({
    kind: "standalone",
    artifact,
    address,
    codeHash,
    constructorArgs: "0x",
  });
  return parseDeploymentManifest(
    JSON.stringify({
      status: "finalized",
      chainId: 11155111,
      deployer: admin,
      release: { buildInfoSha256: codeHash },
      contracts: {
        DatasetRegistry: contract("src/DatasetRegistry.sol:DatasetRegistry", registry),
        ConsentManager: contract("src/ConsentManager.sol:ConsentManager", manager),
        UsageLog: contract("src/UsageLog.sol:UsageLog", usageLog),
      },
      settings: { adminDelay: 86400 },
      externalDependencies: { Logger: logger },
    }),
  );
}

type Chain = {
  calls: Record<string, string>;
  code: string;
  codeHash: string;
  granted: Set<string>;
};

function chain(): Chain {
  return {
    calls: {
      [`${manager}:getDatasetRegistry()(address)`]: registry,
      [`${usageLog}:getConsentManager()(address)`]: manager,
      [`${usageLog}:defaultAdmin()(address)`]: admin,
      [`${usageLog}:defaultAdminDelay()(uint48)`]: "86400 [8.64e4]",
      [`${usageLog}:DEFAULT_ADMIN_ROLE()(bytes32)`]: adminRole,
      [`${usageLog}:LOGGER_ROLE()(bytes32)`]: loggerRole,
    },
    code: "0x6080",
    codeHash,
    granted: new Set([`${adminRole}:${admin}`, `${loggerRole}:${logger}`]),
  };
}

function runner(state: Chain): CommandRunner {
  return async (command, args) => {
    assert.equal(command, "cast");
    if (args[0] === "keccak") return `${state.codeHash}\n`;
    if (args[0] === "rpc" && args[3] === "eth_getCode") return JSON.stringify(state.code);
    if (args[0] === "call" && args[2] === "hasRole(bytes32,address)(bool)") {
      return state.granted.has(`${args[3]}:${args[4]}`) ? "true\n" : "false\n";
    }
    if (args[0] === "call") {
      const value = state.calls[`${args[1]}:${args[2]}`];
      if (value === undefined) throw new Error(`unexpected call ${args.join(" ")}`);
      return `${value}\n`;
    }
    throw new Error(`unexpected command ${args.join(" ")}`);
  };
}

test("extracts unique transaction hashes from a broadcast", () => {
  const upperCaseHash = `0x${"A".repeat(64)}`;
  const broadcast = { transactions: [{ hash: upperCaseHash }, { hash: transactionHash(2) }] };
  assert.deepEqual(extractBroadcastTransactionHashes(JSON.stringify(broadcast)), [
    upperCaseHash.toLowerCase(),
    transactionHash(2),
  ]);
  assert.throws(() => extractBroadcastTransactionHashes("{"), /broadcast JSON is invalid/);
  assert.throws(() => extractBroadcastTransactionHashes(JSON.stringify({ transactions: [] })), /non-empty array/);
  assert.throws(
    () => extractBroadcastTransactionHashes(JSON.stringify({ transactions: [{ hash: "0x1" }] })),
    /32-byte transaction hash/,
  );
  assert.throws(
    () =>
      extractBroadcastTransactionHashes(
        JSON.stringify({ transactions: [{ hash: transactionHash(1) }, { hash: transactionHash(1) }] }),
      ),
    /duplicate transaction hash/,
  );
});

test("loads successful receipts and rejects failed ones", async () => {
  const receiptJson = (status: string) =>
    JSON.stringify({
      transactionHash: transactionHash(1),
      status,
      blockNumber: "0x64",
      blockHash,
      contractAddress: registry,
    });
  const ok: CommandRunner = async () => receiptJson("0x1");
  assert.deepEqual(await loadTransactionReceipts(ok, rpcUrl, [transactionHash(1)]), [receipt(1, 100)]);

  const failed: CommandRunner = async () => receiptJson("0x0");
  await assert.rejects(loadTransactionReceipts(failed, rpcUrl, [transactionHash(1)]), /failed with status 0/);
  const missing: CommandRunner = async () => "null";
  await assert.rejects(loadTransactionReceipts(missing, rpcUrl, [transactionHash(1)]), /receipt is missing/);
  await assert.rejects(loadTransactionReceipts(ok, rpcUrl, []), /at least one transaction hash/);
});

test("waits until the finalized block covers every receipt and checks they are canonical", async () => {
  const heights = [99, 100];
  const messages: string[] = [];
  let sleeps = 0;
  const run: CommandRunner = async (_command, args) => {
    if (args[3] === "eth_getBlockByNumber" && args[4] === "finalized") {
      return JSON.stringify({ number: `0x${heights.shift()!.toString(16)}` });
    }
    if (args[3] === "eth_getBlockByNumber" && args[4] === "0x64") return JSON.stringify({ number: "0x64", hash: blockHash });
    throw new Error(`unexpected command ${args.join(" ")}`);
  };
  await waitForFinality(run, rpcUrl, [receipt(1, 100)], {
    sleep: async () => {
      sleeps += 1;
    },
    progress: (message) => messages.push(message),
  });
  assert.equal(sleeps, 1);
  assert.match(messages[0]!, /waiting for receipt block 100/);
  assert.match(messages[1]!, /covers all receipt blocks/);
});

test("rejects a receipt block that was reorganized away", async () => {
  const run: CommandRunner = async (_command, args) => {
    if (args[4] === "finalized") return JSON.stringify({ number: "0x64" });
    return JSON.stringify({ number: "0x64", hash: `0x${"9".repeat(64)}` });
  };
  await assert.rejects(waitForFinality(run, rpcUrl, [receipt(1, 100)]), /is not canonical/);
});

test("stops waiting for finality when cancelled", async () => {
  const controller = new AbortController();
  controller.abort();
  const run: CommandRunner = async () => JSON.stringify({ number: "0x1" });
  await assert.rejects(
    waitForFinality(run, rpcUrl, [receipt(1, 100)], { signal: controller.signal }),
    /cancelled/,
  );
});

test("detects Amsterdam from the block access list hash of the latest block", async () => {
  const block = (fields: Record<string, string>): CommandRunner => async (_command, args) => {
    assert.deepEqual(args.slice(3), ["eth_getBlockByNumber", "latest", "false"]);
    return JSON.stringify({ number: "0x64", hash: blockHash, ...fields });
  };
  assert.equal(await detectRuntimeHardfork(block({ blockAccessListHash: blockHash }), rpcUrl), "amsterdam");
  assert.equal(await detectRuntimeHardfork(block({}), rpcUrl), undefined);
  const failing: CommandRunner = async () => {
    throw new Error("connection refused");
  };
  await assert.rejects(detectRuntimeHardfork(failing, rpcUrl), /could not read latest block/);
});

test("accepts a live deployment that matches the manifest", async () => {
  await verifyLiveDeployment(runner(chain()), rpcUrl, manifest(), { admin, adminDelay: 86400 });
});

test("rejects a live deployment that differs from the manifest", async () => {
  const cases: Array<[(state: Chain) => void, RegExp]> = [
    [(state) => { state.codeHash = blockHash; }, /code hash does not match manifest/],
    [(state) => { state.code = "0x"; }, /has no runtime bytecode/],
    [(state) => { state.calls[`${manager}:getDatasetRegistry()(address)`] = usageLog; }, /dataset registry does not match/],
    [(state) => { state.calls[`${usageLog}:getConsentManager()(address)`] = registry; }, /consent manager does not match/],
    [(state) => { state.calls[`${usageLog}:defaultAdmin()(address)`] = logger; }, /admin does not match/],
    [(state) => { state.calls[`${usageLog}:defaultAdminDelay()(uint48)`] = "0"; }, /admin delay does not match/],
    [(state) => { state.granted.delete(`${loggerRole}:${logger}`); }, /logger role is missing/],
  ];
  for (const [mutate, message] of cases) {
    const state = chain();
    mutate(state);
    await assert.rejects(verifyLiveDeployment(runner(state), rpcUrl, manifest(), { admin, adminDelay: 86400 }), message);
  }
});

test("accepts a handed-over admin when no deploy-time expectations are given", async () => {
  const state = chain();
  state.calls[`${usageLog}:defaultAdmin()(address)`] = logger;
  state.granted.add(`${adminRole}:${logger}`);
  await verifyLiveDeployment(runner(state), rpcUrl, manifest());
});
