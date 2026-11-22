import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";
import {
  classifyDeployCanonicalState,
  hashRawBytes,
  parseDeploymentManifest,
  parsePendingDeploy,
  renderAddressBook,
  type DeploymentManifest,
  type DeploymentTransaction,
  type PendingDeploy,
} from "./deployment-state.ts";
import {
  extractBroadcastTransactionHashes,
  loadTransactionReceipts,
  verifyLiveDeployment,
  waitForFinality,
  type CommandRunner,
} from "./deployment-chain.ts";
import { verifyContractSources } from "./deployment-sources.ts";

const commands = ["deploy", "finalize-deploy", "check-live", "verify-sources"] as const;
const releasePaths = [
  "src",
  "script",
  "foundry.toml",
  "foundry.lock",
  "remappings.txt",
  "package.json",
  "package-lock.json",
  "lib",
] as const;

export const networkConfigs = {
  sepolia: {
    chainId: 11155111,
    rpcVariable: "RPC_SEPOLIA",
    privateKeyVariable: "PRIVATE_KEY_SEPOLIA",
    environmentSuffix: "SEPOLIA",
    adminDelay: 86_400,
  },
  mainnet: {
    chainId: 1,
    rpcVariable: "RPC_MAINNET",
    privateKeyVariable: "PRIVATE_KEY_MAINNET",
    environmentSuffix: "MAINNET",
    adminDelay: 432_000,
  },
} as const satisfies Record<string, NetworkConfig>;

type NetworkConfig = {
  chainId: number;
  rpcVariable: string;
  privateKeyVariable: string;
  environmentSuffix: string;
  adminDelay: number;
};
type Network = keyof typeof networkConfigs;
type Command = (typeof commands)[number];
type Context = {
  network: Network;
  root: string;
  deploymentsRoot: string;
  pendingRoot: string;
  environment: NodeJS.ProcessEnv;
  cast: string;
  forge: string;
  git: string;
  pollIntervalMs?: number;
  signal?: AbortSignal;
};
type Paths = {
  directory: string;
  pending: string;
  buildInfo: string;
  broadcast: string;
  latest: string;
  addresses: string;
};
type Build = {
  hash: string;
  gzip: Buffer;
  outputDirectory: string;
  cacheDirectory: string;
};
type DeployOptions = {
  fresh: boolean;
  confirmMainnetReplacement: boolean;
};
type DeploymentInputs = {
  privateKey: string;
  logger: string;
  adminDelay: number;
};

export type SignalHandling = { signal: AbortSignal; dispose: () => void };

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const zeroAddress = `0x${"0".repeat(40)}`;
const networks = Object.keys(networkConfigs) as Network[];
const usage = `Usage: deployment.ts <command> <network> [args...]\nCommands: ${commands.join(", ")}\nNetworks: ${networks.join(", ")}`;

async function deploy(context: Context, options: DeployOptions): Promise<void> {
  if (
    context.network === "mainnet" &&
    options.fresh &&
    existsSync(canonicalManifestPath(context)) &&
    !options.confirmMainnetReplacement
  ) {
    throw new Error("pass --confirm-replace-mainnet-manifest to replace the mainnet deployment manifest");
  }
  const inputs = deploymentInputs(context);

  phase("Deployment preflight");
  await broadcastPreflight(context);
  ensureNoPendingOperation(context);
  const previousHash = prepareDeploy(context, options.fresh);

  const workspace = mkdtempSync(join(tmpdir(), "consent-ledger-deploy-"));
  const forgeIoDirectory = join(context.root, ".deployment", `.deploy-${randomUUID()}`);
  try {
    mkdirSync(forgeIoDirectory, { recursive: true });
    phase("Build contracts");
    const build = await buildContracts(context, workspace);
    ensureNoPendingOperation(context);
    const pending = newPendingDeploy(context, previousHash, build.hash);
    const output = join(forgeIoDirectory, "deploy-output.json");
    writeAtomicFile(output, json(pending));
    retainPendingStart(operationPaths(context), build.gzip, pending);

    let forgeError: unknown;
    try {
      phase("Broadcast deployment");
      await runDeployScript(context, workspace, output, build, inputs);
    } catch (error) {
      forgeError = error;
    }

    const recorded = recordDeploy(context, workspace, output, build, pending, inputs);
    if (forgeError !== undefined) throw forgeError;
    if (!recorded) throw new Error("Forge did not produce complete deployment evidence");
  } finally {
    rmSync(workspace, { recursive: true, force: true });
    rmSync(forgeIoDirectory, { recursive: true, force: true });
  }

  await finalizeDeploy(context, true);
}

async function finalizeDeploy(context: Context, preflightDone = false): Promise<void> {
  if (!preflightDone) await finalizePreflight(context);
  const paths = operationPaths(context);
  let pending = readDeployPending(context, paths);
  authenticateEvidence(paths, pending.release.buildInfoSha256, pending.broadcastSha256);

  const state = classifyDeployCanonicalState(hashFile(paths.latest), pending);
  if (state === "unexpected") throw new Error("canonical manifest does not match pending deployment");
  if (state === "result") {
    finishPending(paths.pending, pending);
    await verifyPublishedSources(context);
    return;
  }
  if (pending.status === "finalized") throw new Error("finalized deployment manifest is missing");

  const rpcUrl = rpc(context);
  phase("Confirm transactions and wait for finalized blocks");
  const receipts = await finalizedReceipts(context, paths.broadcast, rpcUrl);
  const result = pending.result!;
  const manifest: DeploymentManifest = {
    ...result,
    status: "finalized",
    finalizedAt: pending.finalizedAt ?? new Date().toISOString(),
    deploymentBlock: Math.min(...receipts.map((receipt) => receipt.blockNumber)),
    transactions: receipts,
  };
  phase("Check live deployment");
  await verifyLiveDeployment(commandRunner(context), rpcUrl, manifest, {
    admin: result.deployer,
    adminDelay: result.settings.adminDelay,
  });

  const manifestBytes = json(manifest);
  pending = {
    ...pending,
    result: manifest,
    finalizedAt: manifest.finalizedAt!,
    resultManifestSha256: hashRawBytes(Buffer.from(manifestBytes)),
  };
  writeAtomicFile(paths.pending, json(pending));
  phase("Publish deployment manifest");
  publish(context, paths, pending.release.buildInfoSha256, manifestBytes);
  finishPending(paths.pending, pending);
  await verifyPublishedSources(context);
}

async function checkLive(context: Context): Promise<void> {
  await ensureChainId(context);
  const manifest = readCanonicalManifest(context);
  await verifyLiveDeployment(commandRunner(context), rpc(context), manifest);
  console.error(`Live ${context.network} deployment matches the manifest`);
  printContractAddresses(manifest);
}

async function verifySources(context: Context): Promise<void> {
  required(context, "ETHERSCAN_API_KEY");
  await ensureChainId(context);
  const manifest = readCanonicalManifest(context);
  phase("Verify contract sources");
  await verifyContractSources(manifest, {
    chainId: networkConfigs[context.network].chainId,
    root: context.root,
    runForge: async (args) => {
      await runProcess(context.forge, args, {
        environment: context.environment,
        signal: context.signal,
        terminal: true,
      });
    },
  });
}

async function verifyPublishedSources(context: Context): Promise<void> {
  try {
    await verifySources(context);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(
      `deployment is finalized and published, but source verification failed: ${message}\n` +
        `Retry with: just verify ${context.network}`,
      { cause: error },
    );
  }
  printContractAddresses(readCanonicalManifest(context));
}

function phase(message: string): void {
  console.error(`\n== ${message} ==`);
}

function printContractAddresses(manifest: DeploymentManifest): void {
  console.error("Deployed contract addresses:");
  for (const [name, contract] of Object.entries(manifest.contracts)) console.error(`  ${name}: ${contract.address}`);
  if (manifest.deploymentBlock !== undefined) console.error(`  deployment block: ${manifest.deploymentBlock}`);
}

async function runCli(args: readonly string[], signal?: AbortSignal): Promise<void> {
  const [commandValue, networkValue, ...rest] = args;
  const command = parseCommand(commandValue);
  const network = parseNetwork(networkValue);
  const context = createContext(network, signal);

  switch (command) {
    case "deploy":
      await deploy(context, parseDeployOptions(rest));
      return;
    case "finalize-deploy":
      noArguments(command, rest);
      await finalizeDeploy(context);
      return;
    case "check-live":
      noArguments(command, rest);
      await checkLive(context);
      return;
    case "verify-sources":
      noArguments(command, rest);
      await verifySources(context);
  }
}

function createContext(network: Network, signal?: AbortSignal): Context {
  const pollIntervalMs = process.env.FINALITY_POLL_INTERVAL_MS;
  return {
    network,
    root,
    deploymentsRoot: process.env.DEPLOYMENTS_ROOT ?? join(root, "deployments"),
    pendingRoot: process.env.PENDING_ROOT ?? join(root, ".deployment"),
    environment: process.env,
    cast: process.env.CAST_BIN ?? "cast",
    forge: process.env.FORGE_BIN ?? "forge",
    git: process.env.GIT_BIN ?? "git",
    ...(pollIntervalMs === undefined ? {} : { pollIntervalMs: Number(pollIntervalMs) }),
    signal,
  };
}

function operationPaths(context: Context): Paths {
  const directory = join(context.pendingRoot, context.network);
  return {
    directory,
    pending: join(directory, "pending-deploy.json"),
    buildInfo: join(directory, "pending-deploy.build-info.json.gz"),
    broadcast: join(directory, "pending-deploy.broadcast.json"),
    latest: canonicalManifestPath(context),
    addresses: join(context.deploymentsRoot, context.network, "addresses.json"),
  };
}

function parseCommand(value: string | undefined): Command {
  if (value === undefined) throw new Error(usage);
  if (!commands.includes(value as Command)) throw new Error(`unsupported command: ${value}`);
  return value as Command;
}

function parseNetwork(value: string | undefined): Network {
  if (value === undefined) throw new Error(usage);
  if (!networks.includes(value as Network)) throw new Error(`unsupported network: ${value}`);
  return value as Network;
}

function parseDeployOptions(args: readonly string[]): DeployOptions {
  if (args.length === 0) return { fresh: false, confirmMainnetReplacement: false };
  if (args.length === 1 && args[0] === "--fresh") {
    return { fresh: true, confirmMainnetReplacement: false };
  }
  if (args.length === 2 && args[0] === "--fresh" && args[1] === "--confirm-replace-mainnet-manifest") {
    return { fresh: true, confirmMainnetReplacement: true };
  }
  throw new Error(`unsupported deploy arguments: ${args.join(" ")}`);
}

function noArguments(command: Command, args: readonly string[]): void {
  if (args.length !== 0) throw new Error(`${command} does not accept arguments`);
}

async function broadcastPreflight(context: Context): Promise<void> {
  await ensureChainId(context);
  confirmMainnet(context);
  required(context, "ETHERSCAN_API_KEY");
  await ensureCleanReleaseSource(context);
}

async function finalizePreflight(context: Context): Promise<void> {
  await ensureChainId(context);
  confirmMainnet(context);
}

async function ensureChainId(context: Context): Promise<void> {
  const actual = (
    await runProcess(context.cast, ["chain-id", "--rpc-url", rpc(context)], { signal: context.signal })
  ).trim();
  const expected = networkConfigs[context.network].chainId;
  if (actual !== String(expected)) throw new Error(`${context.network} RPC chain ID must be ${expected}, got ${actual}`);
}

function confirmMainnet(context: Context): void {
  if (context.network === "mainnet" && context.environment.CONFIRM_MAINNET !== "yes") {
    throw new Error("set CONFIRM_MAINNET=yes before operating on mainnet");
  }
}

async function ensureCleanReleaseSource(context: Context): Promise<void> {
  const output = await runProcess(
    context.git,
    ["-C", context.root, "status", "--porcelain", "--untracked-files=all", "--", ...releasePaths],
    { signal: context.signal },
  );
  if (output.length !== 0) throw new Error(`deployment source is dirty under ${context.root}; commit it first`);
}

function prepareDeploy(context: Context, fresh: boolean): string | null {
  const paths = operationPaths(context);
  if (!existsSync(paths.latest)) return null;
  if (!fresh) throw new Error(`canonical ${context.network} deployment already exists; pass --fresh`);
  return hashFile(paths.latest) ?? null;
}

function ensureNoPendingOperation(context: Context): void {
  const path = operationPaths(context).pending;
  if (!existsSync(path)) return;
  let status: unknown;
  try {
    status = (JSON.parse(readFileSync(path, "utf8")) as { status?: unknown }).status;
  } catch {
    throw new Error(`pending operation file is invalid: ${path}`);
  }
  if (status !== "finalized") {
    throw new Error(`pending operation already exists: ${path}\nResume it with: just finalize-deploy ${context.network}`);
  }
}

async function buildContracts(context: Context, workspace: string): Promise<Build> {
  const outputDirectory = join(workspace, "out");
  const cacheDirectory = join(workspace, "cache");
  await runProcess(
    context.forge,
    [
      "build",
      "--root",
      context.root,
      "--out",
      outputDirectory,
      "--cache-path",
      cacheDirectory,
      "--build-info",
      "--skip",
      "test",
    ],
    { signal: context.signal, terminal: true },
  );
  const directory = join(outputDirectory, "build-info");
  const files = existsSync(directory) ? readdirSync(directory).filter((name) => name.endsWith(".json")) : [];
  if (files.length !== 1) throw new Error("Forge build must produce exactly one build-info JSON");
  const raw = readFileSync(join(directory, files[0]!));
  return {
    hash: hashRawBytes(raw),
    gzip: gzipSync(raw, { level: 9 }),
    outputDirectory,
    cacheDirectory,
  };
}

function newPendingDeploy(context: Context, previousHash: string | null, buildHash: string): PendingDeploy {
  return {
    status: "pending",
    operation: "deploy",
    network: context.network,
    chainId: networkConfigs[context.network].chainId,
    previousManifestSha256: previousHash,
    release: { buildInfoSha256: buildHash },
    broadcastSha256: null,
    result: null,
    finalizedAt: null,
    resultManifestSha256: null,
  };
}

async function runDeployScript(
  context: Context,
  workspace: string,
  output: string,
  build: Build,
  inputs: DeploymentInputs,
): Promise<void> {
  await runProcess(
    context.forge,
    [
      "script",
      "script/Deploy.s.sol:Deploy",
      "--root",
      context.root,
      "--out",
      build.outputDirectory,
      "--cache-path",
      build.cacheDirectory,
      "--broadcast",
      "--rpc-url",
      rpc(context),
      "--slow",
    ],
    {
      environment: {
        ...context.environment,
        PRIVATE_KEY: inputs.privateKey,
        LOGGER_ADDR: inputs.logger,
        ADMIN_DELAY: String(inputs.adminDelay),
        BUILD_INFO_SHA256: build.hash,
        DEPLOYMENT_OUTPUT: output,
        FOUNDRY_BROADCAST: join(workspace, "broadcast"),
      },
      signal: context.signal,
      terminal: true,
    },
  );
}

function recordDeploy(
  context: Context,
  workspace: string,
  output: string,
  build: Build,
  expected: PendingDeploy,
  inputs: DeploymentInputs,
): boolean {
  const broadcast = findBroadcast(context, workspace, "Deploy.s.sol");
  if (!broadcast || !existsSync(output)) return false;
  const parsed = parsePendingDeploy(readFileSync(output, "utf8"));
  if (parsed.result === null) throw new Error("Forge deployment output is incomplete");
  if (parsed.result.release.buildInfoSha256 !== build.hash) throw new Error("Forge deployment used unexpected build-info");
  if (parsed.result.chainId !== networkConfigs[context.network].chainId) {
    throw new Error("Forge deployment ran on an unexpected chain");
  }
  if (parsed.result.externalDependencies.Logger?.toLowerCase() !== inputs.logger.toLowerCase()) {
    throw new Error("Forge deployment logger is unexpected");
  }
  if (parsed.result.settings.adminDelay !== inputs.adminDelay) throw new Error("Forge deployment admin delay is unexpected");

  const broadcastBytes = readFileSync(broadcast);
  const pending: PendingDeploy = {
    ...expected,
    result: parsed.result,
    broadcastSha256: hashRawBytes(broadcastBytes),
  };
  retainPendingEvidence(operationPaths(context), build.gzip, broadcastBytes, pending);
  return true;
}

function retainPendingEvidence(paths: Paths, buildInfo: Buffer, broadcast: Buffer, pending: PendingDeploy): void {
  mkdirSync(paths.directory, { recursive: true });
  writeAtomicFile(paths.buildInfo, buildInfo);
  writeAtomicFile(paths.broadcast, broadcast);
  writeAtomicFile(paths.pending, json(pending));
}

function retainPendingStart(paths: Paths, buildInfo: Buffer, pending: PendingDeploy): void {
  mkdirSync(paths.directory, { recursive: true });
  writeAtomicFile(paths.buildInfo, buildInfo);
  writeAtomicFile(paths.pending, json(pending));
}

function findBroadcast(context: Context, workspace: string, script: string): string | undefined {
  const directory = join(workspace, "broadcast", script, String(networkConfigs[context.network].chainId));
  const files = existsSync(directory) ? readdirSync(directory).filter((name) => /^run-[0-9]+\.json$/.test(name)) : [];
  if (files.length > 1) throw new Error("Forge produced multiple timestamped broadcast files");
  return files.length === 1 ? join(directory, files[0]!) : undefined;
}

function readDeployPending(context: Context, paths: Paths): PendingDeploy {
  if (!existsSync(paths.pending)) throw new Error(`pending operation does not exist: ${paths.pending}`);
  const pending = parsePendingDeploy(readFileSync(paths.pending, "utf8"));
  if (pending.network !== context.network) throw new Error("pending deployment does not match command");
  if (!pending.result || !pending.broadcastSha256) throw new Error("pending deployment evidence is incomplete");
  return pending;
}

function authenticateEvidence(paths: Paths, buildHash: string, broadcastHash: string | null): void {
  authenticateBuildInfo(paths.buildInfo, buildHash);
  if (!broadcastHash || hashFile(paths.broadcast) !== broadcastHash) throw new Error("pending broadcast hash does not match");
}

function authenticateBuildInfo(path: string, expectedHash: string): Buffer {
  const raw = gunzipSync(readFileSync(path));
  if (hashRawBytes(raw) !== expectedHash) throw new Error(`build-info hash does not match: ${path}`);
  return raw;
}

async function finalizedReceipts(
  context: Context,
  broadcast: string,
  rpcUrl: string,
): Promise<DeploymentTransaction[]> {
  const hashes = extractBroadcastTransactionHashes(readFileSync(broadcast, "utf8"));
  const receipts = await loadTransactionReceipts(commandRunner(context), rpcUrl, hashes);
  await waitForFinality(commandRunner(context), rpcUrl, receipts, {
    signal: context.signal,
    ...(context.pollIntervalMs === undefined ? {} : { pollIntervalMs: context.pollIntervalMs }),
  });
  return receipts;
}

function commandRunner(context: Context): CommandRunner {
  return (command, args, options) => {
    if (command !== "cast") throw new Error(`unsupported command: ${command}`);
    return runProcess(context.cast, args, { signal: options.signal ?? context.signal });
  };
}

function publish(context: Context, paths: Paths, buildHash: string, manifest: string): void {
  const destination = retainedBuildInfoPath(context, buildHash);
  mkdirSync(dirname(destination), { recursive: true });
  if (existsSync(destination)) authenticateBuildInfo(destination, buildHash);
  else writeAtomicFile(destination, readFileSync(paths.buildInfo));
  writeAtomicFile(paths.addresses, json(renderAddressBook(context.network, parseDeploymentManifest(manifest))));
  writeAtomicFile(paths.latest, manifest);
  pruneBuildInfo(context, buildHash);
}

function finishPending(path: string, pending: PendingDeploy): void {
  if (pending.status !== "finalized") writeAtomicFile(path, json({ ...pending, status: "finalized" }));
}

function retainedBuildInfoPath(context: Context, hash: string): string {
  return join(context.deploymentsRoot, context.network, "build-info", `${hash.slice(2)}.json.gz`);
}

function pruneBuildInfo(context: Context, retainedHash: string): void {
  const directory = dirname(retainedBuildInfoPath(context, retainedHash));
  if (!existsSync(directory)) return;
  const retained = `${retainedHash.slice(2)}.json.gz`;
  for (const file of readdirSync(directory)) {
    if (file.endsWith(".json.gz") && file !== retained) rmSync(join(directory, file), { force: true });
  }
}

function deploymentInputs(context: Context): DeploymentInputs {
  const config = networkConfigs[context.network];
  return {
    privateKey: required(context, config.privateKeyVariable),
    logger: requiredNonZeroAddress(context, `LOGGER_ADDR_${config.environmentSuffix}`),
    adminDelay: config.adminDelay,
  };
}

function required(context: Context, name: string): string {
  const value = context.environment[name];
  if (!value) throw new Error(`required environment variable is unset for ${context.network}: ${name}`);
  return value;
}

function requiredNonZeroAddress(context: Context, name: string): string {
  const value = required(context, name);
  if (!/^0x[0-9a-fA-F]{40}$/.test(value) || value.toLowerCase() === zeroAddress) {
    throw new Error(`required environment variable must be a non-zero address for ${context.network}: ${name}`);
  }
  return value;
}

function rpc(context: Context): string {
  return required(context, networkConfigs[context.network].rpcVariable);
}

function canonicalManifestPath(context: Context): string {
  return join(context.deploymentsRoot, context.network, "latest.json");
}

function readCanonicalManifest(context: Context): DeploymentManifest {
  const path = canonicalManifestPath(context);
  if (!existsSync(path)) throw new Error(`canonical ${context.network} deployment does not exist: ${path}`);
  return parseDeploymentManifest(readFileSync(path, "utf8"));
}

function hashFile(path: string): string | undefined {
  return existsSync(path) ? hashRawBytes(readFileSync(path)) : undefined;
}

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export async function runProcess(
  command: string,
  args: readonly string[],
  options: { environment?: NodeJS.ProcessEnv; signal?: AbortSignal; terminal?: boolean } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: options.environment,
      shell: false,
      signal: options.signal,
      stdio: options.terminal ? "inherit" : "pipe",
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let processError: Error | undefined;
    child.stdout?.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr?.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", (error) => {
      processError = new Error(`could not run ${command}: ${error.message}`, { cause: error });
      if (child.pid === undefined) reject(processError);
    });
    child.once("close", (code, signal) => {
      if (processError) {
        reject(processError);
        return;
      }
      if (code !== 0) {
        const details = Buffer.concat(stderr).toString("utf8").trim();
        reject(
          new Error(
            `${command} exited with code ${code ?? "unknown"}${signal ? ` (${signal})` : ""}${details ? `: ${details}` : ""}`,
          ),
        );
        return;
      }
      resolve(Buffer.concat(stdout).toString("utf8"));
    });
  });
}

export function writeAtomicFile(path: string, content: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${randomUUID()}.tmp`);
  let descriptor: number | undefined;
  try {
    descriptor = openSync(temporary, "wx", 0o600);
    writeFileSync(descriptor, content);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, path);
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporary, { force: true });
    throw error;
  }
}

export function installSignalHandling(): SignalHandling {
  const controller = new AbortController();
  const abort = (): void => controller.abort();
  process.on("SIGINT", abort);
  process.on("SIGTERM", abort);
  return {
    signal: controller.signal,
    dispose: () => {
      process.off("SIGINT", abort);
      process.off("SIGTERM", abort);
    },
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const signals = installSignalHandling();
  void runCli(process.argv.slice(2), signals.signal)
    .catch((error: unknown) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    })
    .finally(signals.dispose);
}
