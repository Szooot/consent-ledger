// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {UsageLog} from "../src/UsageLog.sol";
import {UsageLogHelper} from "./mocks/UsageLogHelper.sol";

/**
 * @title UsageLogTest
 * @notice Functional and security tests for UsageLog. The logger stands for the key service, the company has
 *         a valid consent in the consent manager mock and the admin only manages loggers.
 */
contract UsageLogTest is UsageLogHelper {
    function testLoggerRole() public view {
        assertEq(usageLog.LOGGER_ROLE(), LOGGER_ROLE);
    }

    function testInitialState() public view {
        assertEq(usageLog.getConsentManager(), address(consentManager));
        assertEq(usageLog.defaultAdmin(), admin);
        assertEq(usageLog.defaultAdminDelay(), ADMIN_DELAY);
        assertTrue(usageLog.hasRole(LOGGER_ROLE, logger));
        assertFalse(usageLog.hasRole(LOGGER_ROLE, admin));
        assertEq(usageLog.getUsageCount(DATASET_ID, company, PURPOSE), 0);
        assertFalse(usageLog.isEvidenceLogged(EVIDENCE));
    }

    function testRevertWhenDeployedWithoutConsentManager() public {
        vm.expectRevert(UsageLog.InvalidConsentManager.selector);
        new UsageLog(address(0), ADMIN_DELAY, admin, logger);
    }

    function testRevertWhenDeployedWithoutAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new UsageLog(address(consentManager), ADMIN_DELAY, address(0), logger);
    }

    function testRevertWhenDeployedWithoutLogger() public {
        vm.expectRevert(UsageLog.InvalidLogger.selector);
        new UsageLog(address(consentManager), ADMIN_DELAY, admin, address(0));
    }

    function testLogUsage() public {
        vm.expectEmit(true, true, true, true, address(usageLog));
        emit UsageLog.DataUsed(DATASET_ID, company, PURPOSE, EVIDENCE);

        _log(EVIDENCE);

        assertEq(usageLog.getUsageCount(DATASET_ID, company, PURPOSE), 1);
        assertTrue(usageLog.isEvidenceLogged(EVIDENCE));
    }

    function testLogUsageCountsEachUse() public {
        _log(EVIDENCE);
        _log(OTHER_EVIDENCE);

        assertEq(usageLog.getUsageCount(DATASET_ID, company, PURPOSE), 2);
        assertTrue(usageLog.isEvidenceLogged(OTHER_EVIDENCE));
    }

    function testFuzzLogUsage(uint256 datasetId, address grantee, bytes32 purpose, bytes32 evidenceHash) public {
        vm.assume(evidenceHash != bytes32(0));
        consentManager.setValidConsent(datasetId, grantee, purpose, true);

        vm.prank(logger);
        usageLog.logUsage(datasetId, grantee, purpose, evidenceHash);

        assertEq(usageLog.getUsageCount(datasetId, grantee, purpose), 1);
        assertTrue(usageLog.isEvidenceLogged(evidenceHash));
    }

    function testRevertWhenLogWithEmptyEvidence() public {
        vm.expectRevert(UsageLog.EmptyEvidence.selector);
        _log(bytes32(0));
    }

    function testRevertWhenEvidenceAlreadyLogged() public {
        _log(EVIDENCE);

        vm.expectRevert(abi.encodeWithSelector(UsageLog.EvidenceAlreadyLogged.selector, EVIDENCE));
        _log(EVIDENCE);
    }

    function testRevertWhenEvidenceReusedForAnotherConsent() public {
        consentManager.setValidConsent(DATASET_ID, company, OTHER_PURPOSE, true);
        _log(EVIDENCE);

        vm.expectRevert(abi.encodeWithSelector(UsageLog.EvidenceAlreadyLogged.selector, EVIDENCE));
        vm.prank(logger);
        usageLog.logUsage(DATASET_ID, company, OTHER_PURPOSE, EVIDENCE);
    }

    function testRevertWhenLogWithoutConsent() public {
        vm.expectRevert(abi.encodeWithSelector(UsageLog.NoValidConsent.selector, DATASET_ID, company, OTHER_PURPOSE));
        vm.prank(logger);
        usageLog.logUsage(DATASET_ID, company, OTHER_PURPOSE, EVIDENCE);
    }

    function testRevertWhenLogAfterConsentEnds() public {
        _log(EVIDENCE);
        consentManager.setValidConsent(DATASET_ID, company, PURPOSE, false);

        vm.expectRevert(abi.encodeWithSelector(UsageLog.NoValidConsent.selector, DATASET_ID, company, PURPOSE));
        _log(OTHER_EVIDENCE);

        assertEq(usageLog.getUsageCount(DATASET_ID, company, PURPOSE), 1);
        assertFalse(usageLog.isEvidenceLogged(OTHER_EVIDENCE));
    }

    function testRevertWhenAttackerLogsUsage() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, LOGGER_ROLE)
        );
        vm.prank(attacker);
        usageLog.logUsage(DATASET_ID, company, PURPOSE, EVIDENCE);
    }

    function testRevertWhenGranteeLogsOwnUsage() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, company, LOGGER_ROLE)
        );
        vm.prank(company);
        usageLog.logUsage(DATASET_ID, company, PURPOSE, EVIDENCE);
    }

    function testRevertWhenAdminLogsUsage() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, LOGGER_ROLE)
        );
        vm.prank(admin);
        usageLog.logUsage(DATASET_ID, company, PURPOSE, EVIDENCE);
    }

    function testUsageCountsAreScopedToConsent() public {
        _log(EVIDENCE);

        assertEq(usageLog.getUsageCount(DATASET_ID, company, OTHER_PURPOSE), 0);
        assertEq(usageLog.getUsageCount(DATASET_ID, attacker, PURPOSE), 0);
        assertEq(usageLog.getUsageCount(DATASET_ID + 1, company, PURPOSE), 0);
    }

    function testAdminGrantsLoggerRole() public {
        address newLogger = makeAddr("newLogger");

        vm.prank(admin);
        usageLog.grantRole(LOGGER_ROLE, newLogger);

        vm.prank(newLogger);
        usageLog.logUsage(DATASET_ID, company, PURPOSE, EVIDENCE);
        assertEq(usageLog.getUsageCount(DATASET_ID, company, PURPOSE), 1);
    }

    function testAdminRevokesLoggerRole() public {
        vm.prank(admin);
        usageLog.revokeRole(LOGGER_ROLE, logger);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, logger, LOGGER_ROLE)
        );
        _log(EVIDENCE);
    }

    function testRevertWhenAttackerGrantsLoggerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, usageLog.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        usageLog.grantRole(LOGGER_ROLE, attacker);
    }

    function testAdminTransferWaitsForDelay() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        usageLog.beginDefaultAdminTransfer(newAdmin);
        (, uint48 schedule) = usageLog.pendingDefaultAdmin();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vm.prank(newAdmin);
        usageLog.acceptDefaultAdminTransfer();

        vm.warp(schedule + 1);
        vm.prank(newAdmin);
        usageLog.acceptDefaultAdminTransfer();

        assertEq(usageLog.defaultAdmin(), newAdmin);
    }
}
