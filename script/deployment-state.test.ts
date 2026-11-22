import assert from "node:assert/strict";
import { test } from "node:test";
import {
  classifyDeployCanonicalState,
  hashRawBytes,
  parseDeploymentManifest,
  parsePendingDeploy,
  renderAddressBook,
  type PendingDeploy,
} from "./deployment-state.ts";

const address = `0x${"1".repeat(40)}`;
const nextAddress = `0x${"2".repeat(40)}`;
const hash = `0x${"a".repeat(64)}`;
const nextHash = `0x${"b".repeat(64)}`;

function manifest() {
  return {
    status: "finalized",
    finalizedAt: "2026-11-22T12:00:00Z",
    chainId: 11155111,
    deploymentBlock: 100,
    deployer: address,
    release: { buildInfoSha256: hash },
    contracts: {
      DatasetRegistry: {
        kind: "standalone",
        artifact: "src/DatasetRegistry.sol:DatasetRegistry",
        address,
        codeHash: hash,
        constructorArgs: "0x",
      },
      UsageLog: {
        kind: "standalone",
        artifact: "src/UsageLog.sol:UsageLog",
        address: nextAddress,
        codeHash: nextHash,
        constructorArgs: `0x${"00".repeat(32)}`,
      },
    },
    settings: { adminDelay: 86400 },
    externalDependencies: { Logger: nextAddress },
    transactions: [{ hash, status: 1, blockNumber: 100, blockHash: nextHash, contractAddress: address }],
  };
}

function pending(): PendingDeploy {
  return {
    status: "pending",
    operation: "deploy",
    network: "sepolia",
    chainId: 11155111,
    previousManifestSha256: null,
    release: { buildInfoSha256: hash },
    broadcastSha256: nextHash,
    result: parseDeploymentManifest(JSON.stringify(manifest())),
    finalizedAt: null,
    resultManifestSha256: null,
  };
}

test("parses a finalized manifest", () => {
  const parsed = parseDeploymentManifest(JSON.stringify(manifest()));
  assert.equal(parsed.status, "finalized");
  assert.equal(parsed.deploymentBlock, 100);
  assert.equal(parsed.contracts.UsageLog?.address, nextAddress);
  assert.equal(parsed.settings.adminDelay, 86400);
  assert.equal(parsed.transactions?.length, 1);
});

test("parses a pending manifest without finalization fields", () => {
  const value: Record<string, unknown> = manifest();
  delete value.finalizedAt;
  delete value.deploymentBlock;
  delete value.transactions;
  value.status = "pending";
  const parsed = parseDeploymentManifest(JSON.stringify(value));
  assert.equal(parsed.deploymentBlock, undefined);
  assert.equal(parsed.transactions, undefined);
});

test("rejects malformed manifests", () => {
  const cases: Array<[(value: ReturnType<typeof manifest>) => void, RegExp]> = [
    [(value) => { value.deployer = "0x1234"; }, /deployer must be an address/],
    [(value) => { value.contracts.DatasetRegistry.kind = "uups"; }, /kind is unsupported/],
    [(value) => { value.contracts.DatasetRegistry.codeHash = address; }, /codeHash must be a 32-byte hash/],
    [(value) => { value.contracts.DatasetRegistry.constructorArgs = "0x123"; }, /constructorArgs must be hex bytes/],
    [(value) => { value.settings.adminDelay = -1; }, /adminDelay must be an integer/],
    [(value) => { value.status = "done"; }, /status must be pending or finalized/],
    [(value) => { value.externalDependencies.Logger = "logger"; }, /Logger must be an address/],
  ];
  for (const [mutate, message] of cases) {
    const value = manifest();
    mutate(value);
    assert.throws(() => parseDeploymentManifest(JSON.stringify(value)), message);
  }
  assert.throws(() => parseDeploymentManifest("{"), /manifest JSON is invalid/);
  assert.throws(
    () => parseDeploymentManifest(JSON.stringify({ ...manifest(), contracts: JSON.parse('{"__proto__":{}}') })),
    /reserved/,
  );
});

test("parses and rejects pending deployments", () => {
  const parsed = parsePendingDeploy(JSON.stringify(pending()));
  assert.equal(parsed.network, "sepolia");
  assert.equal(parsed.result?.contracts.DatasetRegistry?.address, address);
  assert.throws(() => parsePendingDeploy(JSON.stringify({ ...pending(), operation: "upgrade" })), /must be deploy/);
  assert.throws(() => parsePendingDeploy(JSON.stringify({ ...pending(), broadcastSha256: "0x1" })), /32-byte hash/);
});

test("classifies the canonical manifest against a pending deployment", () => {
  const value = pending();
  assert.equal(classifyDeployCanonicalState(undefined, value), "absent");
  assert.equal(classifyDeployCanonicalState(hash, value), "unexpected");
  assert.equal(classifyDeployCanonicalState(undefined, { ...value, previousManifestSha256: hash }), "unexpected");
  assert.equal(classifyDeployCanonicalState(hash, { ...value, previousManifestSha256: hash }), "source");
  assert.equal(classifyDeployCanonicalState(nextHash, { ...value, resultManifestSha256: nextHash }), "result");
});

test("hashes raw bytes with SHA-256", () => {
  assert.equal(
    hashRawBytes(Buffer.from("consent-ledger")),
    "0xe1db44280d25616e3e90342c58aedf6ab18ca7b93b5b102321e1be9164db8815",
  );
});

test("renders the address book of a finalized deployment", () => {
  const book = renderAddressBook("sepolia", parseDeploymentManifest(JSON.stringify(manifest())));
  assert.deepEqual(book, {
    network: "sepolia",
    chainId: 11155111,
    deploymentBlock: 100,
    contracts: { DatasetRegistry: address, UsageLog: nextAddress },
  });
  const value: Record<string, unknown> = { ...manifest(), status: "pending" };
  assert.throws(
    () => renderAddressBook("sepolia", parseDeploymentManifest(JSON.stringify(value))),
    /requires a finalized manifest/,
  );
});
