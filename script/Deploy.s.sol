// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ConsentManager} from "../src/ConsentManager.sol";
import {DatasetRegistry} from "../src/DatasetRegistry.sol";
import {UsageLog} from "../src/UsageLog.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";

/**
 * @title Deploy
 * @notice Deploys DatasetRegistry, ConsentManager and UsageLog in dependency order and writes the pending
 *         deployment manifest. Run it through `just deploy <network>`, which builds the release, records the
 *         evidence and finalizes the manifest.
 * @dev Reads PRIVATE_KEY, LOGGER_ADDR, ADMIN_DELAY, BUILD_INFO_SHA256 and DEPLOYMENT_OUTPUT from the environment.
 *      The deployer becomes the UsageLog admin.
 */
contract Deploy is DeployUtils {
    using stdJson for string;

    /**
     * @notice Address that broadcasts the deployment and becomes the UsageLog admin.
     */
    address internal deployer;

    /**
     * @notice Key service address granted LOGGER_ROLE in UsageLog.
     */
    address internal logger;

    /**
     * @notice Seconds a new UsageLog admin has to wait before taking the admin role over.
     */
    uint48 internal adminDelay;

    /**
     * @notice Deployed DatasetRegistry.
     */
    address internal datasetRegistry;

    /**
     * @notice Deployed ConsentManager.
     */
    address internal consentManager;

    /**
     * @notice Deployed UsageLog.
     */
    address internal usageLog;

    /**
     * @notice Deploys the contracts and writes the pending manifest under `.result` of DEPLOYMENT_OUTPUT.
     */
    function run() external {
        string memory outputPath = vm.envString("DEPLOYMENT_OUTPUT");
        string memory buildInfoSha256 = vm.envString("BUILD_INFO_SHA256");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(privateKey);
        logger = vm.envAddress("LOGGER_ADDR");
        adminDelay = SafeCast.toUint48(vm.envUint("ADMIN_DELAY"));
        _ensureDeploymentAddress(logger, "LOGGER_ADDR");

        vm.startBroadcast(privateKey);
        datasetRegistry = address(new DatasetRegistry());
        consentManager = address(new ConsentManager(datasetRegistry));
        usageLog = address(new UsageLog(consentManager, adminDelay, deployer, logger));
        vm.stopBroadcast();

        vm.writeJson(_serializePendingManifest(buildInfoSha256), outputPath, ".result");
    }

    /**
     * @notice Serializes the manifest of this deployment with status "pending".
     * @param buildInfoSha256 SHA-256 of the build-info the contracts were compiled from.
     * @return JSON manifest.
     */
    function _serializePendingManifest(string memory buildInfoSha256) internal returns (string memory) {
        string memory json = "pendingDeployment";
        json.serialize("status", string("pending"));
        json.serialize("chainId", block.chainid);
        json.serialize("release", _serializeRelease(buildInfoSha256));
        json.serialize("deployer", deployer);
        json.serialize("contracts", _serializeContracts());
        json.serialize("settings", _serializeSettings());
        return json.serialize("externalDependencies", _serializeExternalDependencies());
    }

    /**
     * @notice Serializes the release the contracts were built from.
     * @param buildInfoSha256 SHA-256 of the build-info.
     * @return JSON object of the release.
     */
    function _serializeRelease(string memory buildInfoSha256) private returns (string memory) {
        string memory json = "pendingRelease";
        return json.serialize("buildInfoSha256", buildInfoSha256);
    }

    /**
     * @notice Serializes the deployed contracts.
     * @return JSON object keyed by contract name.
     */
    function _serializeContracts() private returns (string memory) {
        string memory json = "pendingContracts";
        json.serialize(
            "DatasetRegistry",
            _serializeStandalone(
                "pendingDatasetRegistry", "src/DatasetRegistry.sol:DatasetRegistry", datasetRegistry, ""
            )
        );
        json.serialize(
            "ConsentManager",
            _serializeStandalone(
                "pendingConsentManager",
                "src/ConsentManager.sol:ConsentManager",
                consentManager,
                abi.encode(datasetRegistry)
            )
        );
        return json.serialize(
            "UsageLog",
            _serializeStandalone(
                "pendingUsageLog",
                "src/UsageLog.sol:UsageLog",
                usageLog,
                abi.encode(consentManager, adminDelay, deployer, logger)
            )
        );
    }

    /**
     * @notice Serializes the settings the contracts were deployed with.
     * @return JSON object of the settings.
     */
    function _serializeSettings() private returns (string memory) {
        string memory json = "pendingSettings";
        return json.serialize("adminDelay", uint256(adminDelay));
    }

    /**
     * @notice Serializes the addresses outside this deployment that the contracts rely on.
     * @return JSON object keyed by dependency name.
     */
    function _serializeExternalDependencies() private returns (string memory) {
        string memory json = "pendingExternalDependencies";
        return json.serialize("Logger", logger);
    }
}
