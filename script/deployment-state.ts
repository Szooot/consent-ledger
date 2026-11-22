import { createHash } from "node:crypto";

export type StandaloneContract = {
  kind: "standalone";
  artifact: string;
  address: string;
  codeHash: string;
  constructorArgs: string;
};
export type ManifestContract = StandaloneContract;

export type DeploymentTransaction = {
  hash: string;
  status: number;
  blockNumber: number;
  blockHash: string;
  contractAddress: string | null;
};
export type DeploymentSettings = {
  adminDelay: number;
};
export type DeploymentManifest = {
  status: "pending" | "finalized";
  finalizedAt?: string;
  chainId: number;
  deploymentBlock?: number;
  deployer: string;
  release: { buildInfoSha256: string };
  contracts: Record<string, ManifestContract>;
  settings: DeploymentSettings;
  externalDependencies: Record<string, string>;
  transactions?: DeploymentTransaction[];
};
export type PendingDeploy = {
  status: "pending" | "finalized";
  operation: "deploy";
  network: string;
  chainId: number;
  previousManifestSha256: string | null;
  release: { buildInfoSha256: string };
  broadcastSha256: string | null;
  result: DeploymentManifest | null;
  finalizedAt: string | null;
  resultManifestSha256: string | null;
};
export type AddressBook = {
  network: string;
  chainId: number;
  deploymentBlock: number;
  contracts: Record<string, string>;
};
export type CanonicalManifestState = "absent" | "source" | "result" | "unexpected";

const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const hashPattern = /^0x[0-9a-fA-F]{64}$/;
const bytesPattern = /^0x(?:[0-9a-fA-F]{2})*$/;

export function parseDeploymentManifest(text: string): DeploymentManifest {
  return manifest(parseJson(text, "manifest"), "manifest");
}

export function parsePendingDeploy(text: string): PendingDeploy {
  const value = object(parseJson(text, "pending"), "pending");
  if (value.operation !== "deploy") throw new Error("pending.operation must be deploy");
  return {
    status: status(value.status, "pending.status"),
    operation: "deploy",
    network: string(value.network, "pending.network"),
    chainId: integer(value.chainId, "pending.chainId"),
    previousManifestSha256: nullableHash(value.previousManifestSha256, "pending.previousManifestSha256"),
    release: release(value.release, "pending.release"),
    broadcastSha256: nullableHash(value.broadcastSha256, "pending.broadcastSha256"),
    result: value.result === null ? null : manifest(value.result, "pending.result"),
    finalizedAt: nullableString(value.finalizedAt, "pending.finalizedAt"),
    resultManifestSha256: nullableHash(value.resultManifestSha256, "pending.resultManifestSha256"),
  };
}

export function hashRawBytes(bytes: Uint8Array): string {
  return `0x${createHash("sha256").update(bytes).digest("hex")}`;
}

export function classifyDeployCanonicalState(current: string | undefined, pending: PendingDeploy): CanonicalManifestState {
  if (current === undefined) return pending.previousManifestSha256 === null ? "absent" : "unexpected";
  if (pending.resultManifestSha256 === current) return "result";
  if (pending.previousManifestSha256 === current) return "source";
  return "unexpected";
}

export function renderAddressBook(network: string, source: DeploymentManifest): AddressBook {
  if (source.status !== "finalized" || source.deploymentBlock === undefined) {
    throw new Error("address book requires a finalized manifest with a deployment block");
  }
  const contracts: Record<string, string> = {};
  for (const [name, contract] of Object.entries(source.contracts)) contracts[name] = contract.address;
  return { network, chainId: source.chainId, deploymentBlock: source.deploymentBlock, contracts };
}

function manifest(input: unknown, path: string): DeploymentManifest {
  const value = object(input, path);
  const contractsValue = object(value.contracts, `${path}.contracts`);
  const contracts: Record<string, ManifestContract> = {};
  for (const [name, item] of Object.entries(contractsValue)) {
    if (["__proto__", "constructor", "prototype"].includes(name)) throw new Error(`${path}.contracts.${name} is reserved`);
    contracts[name] = contract(item, `${path}.contracts.${name}`);
  }
  const dependencies: Record<string, string> = {};
  for (const [name, item] of Object.entries(object(value.externalDependencies, `${path}.externalDependencies`))) {
    dependencies[name] = address(item, `${path}.externalDependencies.${name}`);
  }
  const transactions = value.transactions === undefined
    ? undefined
    : array(value.transactions, `${path}.transactions`).map((item, index) => transaction(item, `${path}.transactions[${index}]`));
  return {
    status: status(value.status, `${path}.status`),
    ...(value.finalizedAt === undefined ? {} : { finalizedAt: string(value.finalizedAt, `${path}.finalizedAt`) }),
    chainId: integer(value.chainId, `${path}.chainId`),
    ...(value.deploymentBlock === undefined
      ? {}
      : { deploymentBlock: integer(value.deploymentBlock, `${path}.deploymentBlock`, 0) }),
    deployer: address(value.deployer, `${path}.deployer`),
    release: release(value.release, `${path}.release`),
    contracts,
    settings: settings(value.settings, `${path}.settings`),
    externalDependencies: dependencies,
    ...(transactions === undefined ? {} : { transactions }),
  };
}

function contract(input: unknown, path: string): ManifestContract {
  const value = object(input, path);
  if (value.kind !== "standalone") throw new Error(`${path}.kind is unsupported`);
  return {
    kind: "standalone",
    artifact: string(value.artifact, `${path}.artifact`),
    address: address(value.address, `${path}.address`),
    codeHash: hash(value.codeHash, `${path}.codeHash`),
    constructorArgs: bytes(value.constructorArgs, `${path}.constructorArgs`),
  };
}

function settings(input: unknown, path: string): DeploymentSettings {
  const value = object(input, path);
  return { adminDelay: integer(value.adminDelay, `${path}.adminDelay`, 0) };
}

function transaction(input: unknown, path: string): DeploymentTransaction {
  const value = object(input, path);
  return {
    hash: hash(value.hash, `${path}.hash`),
    status: integer(value.status, `${path}.status`, 0),
    blockNumber: integer(value.blockNumber, `${path}.blockNumber`, 0),
    blockHash: hash(value.blockHash, `${path}.blockHash`),
    contractAddress: value.contractAddress === null ? null : address(value.contractAddress, `${path}.contractAddress`),
  };
}

function parseJson(text: string, path: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new Error(`${path} JSON is invalid`);
  }
}

function object(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${path} must be an object`);
  return value as Record<string, unknown>;
}

function array(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${path} must be an array`);
  return value;
}

function string(value: unknown, path: string): string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${path} must be a non-empty string`);
  return value;
}

function nullableString(value: unknown, path: string): string | null {
  return value === null ? null : string(value, path);
}

function address(value: unknown, path: string): string {
  const result = string(value, path);
  if (!addressPattern.test(result)) throw new Error(`${path} must be an address`);
  return result;
}

function hash(value: unknown, path: string): string {
  const result = string(value, path);
  if (!hashPattern.test(result)) throw new Error(`${path} must be a 32-byte hash`);
  return result;
}

function nullableHash(value: unknown, path: string): string | null {
  return value === null ? null : hash(value, path);
}

function bytes(value: unknown, path: string): string {
  const result = string(value, path);
  if (!bytesPattern.test(result)) throw new Error(`${path} must be hex bytes`);
  return result;
}

function integer(value: unknown, path: string, minimum = 1): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum) throw new Error(`${path} must be an integer`);
  return value as number;
}

function status(value: unknown, path: string): "pending" | "finalized" {
  if (value !== "pending" && value !== "finalized") throw new Error(`${path} must be pending or finalized`);
  return value;
}

function release(value: unknown, path: string): { buildInfoSha256: string } {
  return { buildInfoSha256: hash(object(value, path).buildInfoSha256, `${path}.buildInfoSha256`) };
}
