// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsageLog} from "../../src/UsageLog.sol";
import {ConsentManagerMock} from "./ConsentManagerMock.sol";

/**
 * @title UsageLogHelper
 * @notice Shared setup for UsageLog tests: an admin, a logger standing for the key service and a company
 *         with a valid consent in the consent manager mock.
 */
abstract contract UsageLogHelper is Test {
    bytes32 internal constant LOGGER_ROLE = keccak256("LOGGER_ROLE");

    uint256 internal constant DATASET_ID = 1;
    bytes32 internal constant PURPOSE = keccak256("train model X v1");
    bytes32 internal constant OTHER_PURPOSE = keccak256("train model X v2");
    bytes32 internal constant EVIDENCE = keccak256("key release 1");
    bytes32 internal constant OTHER_EVIDENCE = keccak256("key release 2");
    uint48 internal constant ADMIN_DELAY = 3 days;

    UsageLog internal usageLog;
    ConsentManagerMock internal consentManager;

    address internal admin;
    address internal logger;
    address internal company;
    address internal attacker;

    function setUp() public {
        admin = makeAddr("admin");
        logger = makeAddr("logger");
        company = makeAddr("company");
        attacker = makeAddr("attacker");

        consentManager = new ConsentManagerMock();
        consentManager.setValidConsent(DATASET_ID, company, PURPOSE, true);
        usageLog = new UsageLog(address(consentManager), ADMIN_DELAY, admin, logger);
    }

    function _log(bytes32 evidenceHash) internal {
        vm.prank(logger);
        usageLog.logUsage(DATASET_ID, company, PURPOSE, evidenceHash);
    }
}
