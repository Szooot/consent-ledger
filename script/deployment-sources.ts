import type { DeploymentManifest } from "./deployment-state.ts";

export type SourceVerificationTarget = {
  label: string;
  address: string;
  artifact: string;
  constructorArgs: string;
};

export type SourceVerificationOptions = {
  chainId: number;
  root: string;
  runForge: (args: readonly string[]) => Promise<void>;
  progress?: (message: string) => void;
};

export function sourceVerificationTargets(manifest: DeploymentManifest): SourceVerificationTarget[] {
  return Object.entries(manifest.contracts).map(([name, contract]) => ({
    label: name,
    address: contract.address,
    artifact: contract.artifact,
    constructorArgs: contract.constructorArgs,
  }));
}

export function verifyContractArgs(target: SourceVerificationTarget, options: SourceVerificationOptions): string[] {
  const args = [
    "verify-contract",
    target.address,
    target.artifact,
    "--root",
    options.root,
    "--chain",
    String(options.chainId),
    "--verifier",
    "etherscan",
    // Etherscan indexes new contracts with a delay and rate-limits status checks; Forge's default
    // 5 tries 5s apart give up too early.
    "--watch",
    "--retries",
    "10",
    "--delay",
    "30",
  ];
  if (target.constructorArgs !== "0x") args.push("--constructor-args", target.constructorArgs);
  return args;
}

// Forge reports a contract Etherscan already verified as success, so a retry only submits the rest.
// Failures are collected so one contract cannot hide the status of the others.
export async function verifyContractSources(
  manifest: DeploymentManifest,
  options: SourceVerificationOptions,
): Promise<void> {
  const targets = sourceVerificationTargets(manifest);
  const progress = options.progress ?? ((message: string) => console.error(message));
  const failures: string[] = [];

  for (const [index, target] of targets.entries()) {
    progress(`[${index + 1}/${targets.length}] Verifying ${target.label} at ${target.address}`);
    try {
      await options.runForge(verifyContractArgs(target, options));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      progress(`  FAILED ${target.label} at ${target.address}: ${message}`);
      failures.push(`${target.label} at ${target.address}: ${message}`);
    }
  }

  if (failures.length !== 0) {
    throw new Error(
      `${failures.length} of ${targets.length} contracts failed source verification:\n` +
        failures.map((failure) => `  - ${failure}`).join("\n"),
    );
  }
}
