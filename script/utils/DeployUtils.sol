// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title DeployUtils
 * @notice Shared helpers for deployment scripts that record what they deployed in the deployment manifest.
 */
abstract contract DeployUtils is Script {
    using stdJson for string;

    /**
     * @notice A required address passed to the script is zero.
     * @dev Selector: 0x1da2bad3
     * @param name Name of the environment variable.
     */
    error InvalidDeploymentAddress(string name);

    /**
     * @notice Reverts when `account` is the zero address.
     * @param account Address to check.
     * @param name Name of the environment variable the address came from.
     */
    function _ensureDeploymentAddress(address account, string memory name) internal pure {
        if (account == address(0)) revert InvalidDeploymentAddress(name);
    }

    /**
     * @notice Serializes a deployed contract that has no proxy.
     * @param objectKey Unique key of the JSON object being built.
     * @param artifact Source path and name of the contract, e.g. "src/UsageLog.sol:UsageLog".
     * @param deployed Address of the deployed contract.
     * @param constructorArgs ABI-encoded constructor arguments, used for source verification.
     * @return JSON object of the contract.
     */
    function _serializeStandalone(
        string memory objectKey,
        string memory artifact,
        address deployed,
        bytes memory constructorArgs
    ) internal returns (string memory) {
        objectKey.serialize("kind", string("standalone"));
        objectKey.serialize("artifact", artifact);
        objectKey.serialize("address", deployed);
        objectKey.serialize("codeHash", deployed.codehash);
        return objectKey.serialize("constructorArgs", constructorArgs);
    }
}
