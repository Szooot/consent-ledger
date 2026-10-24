// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {ConsentManager} from "../src/ConsentManager.sol";
import {Consent} from "../src/types/ConsentTypes.sol";
import {ConsentManagerHelper} from "./mocks/ConsentManagerHelper.sol";
import {DatasetRegistryMock} from "./mocks/DatasetRegistryMock.sol";

/**
 * @title ConsentManagerTest
 * @notice Functional and security tests for ConsentManager. The client owns a dataset and only signs
 *         messages; a relayer submits every transaction and a company receives the consents.
 */
contract ConsentManagerTest is ConsentManagerHelper {
    function testTypeHashes() public view {
        assertEq(manager.GRANT_TYPEHASH(), GRANT_TYPEHASH);
        assertEq(manager.REVOKE_TYPEHASH(), REVOKE_TYPEHASH);
    }

    function testSigningDomain() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            manager.eip712Domain();
        assertEq(name, "ConsentManager");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(manager));
    }

    function testInitialState() public view {
        assertEq(manager.getDatasetRegistry(), address(registry));
        assertEq(manager.nonces(client), 0);
        assertFalse(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
    }

    function testRevertWhenDeployedWithoutRegistry() public {
        vm.expectRevert(ConsentManager.InvalidDatasetRegistry.selector);
        new ConsentManager(address(0));
    }

    function testGetConsentId() public view {
        assertEq(
            manager.getConsentId(DATASET_ID, company, PURPOSE), keccak256(abi.encode(DATASET_ID, company, PURPOSE))
        );
    }

    function testGrantConsentBySig() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);

        vm.expectEmit(true, true, true, true, address(manager));
        emit ConsentManager.ConsentGranted(DATASET_ID, company, PURPOSE, expiresAt);

        vm.prank(relayer);
        bytes32 consentId = manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);

        assertEq(consentId, manager.getConsentId(DATASET_ID, company, PURPOSE));
        assertEq(manager.nonces(client), 1);
        assertTrue(manager.hasValidConsent(DATASET_ID, company, PURPOSE));

        Consent memory consent = manager.getConsent(DATASET_ID, company, PURPOSE);
        assertEq(consent.grantedAt, block.timestamp);
        assertEq(consent.expiresAt, expiresAt);
        assertEq(consent.revokedAt, 0);
    }

    function testGrantConsentBySigAcceptsDeadlineEqualToNow() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 0, block.timestamp);

        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, block.timestamp, signature);

        assertTrue(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
    }

    function testGrantConsentBySigRenewsConsent() public {
        _grant(company, PURPOSE, expiresAt);
        vm.warp(block.timestamp + 1 days);
        deadline = block.timestamp + 1 hours;
        uint64 laterExpiry = expiresAt + 30 days;

        _grant(company, PURPOSE, laterExpiry);

        Consent memory consent = manager.getConsent(DATASET_ID, company, PURPOSE);
        assertEq(consent.grantedAt, block.timestamp);
        assertEq(consent.expiresAt, laterExpiry);
        assertEq(manager.nonces(client), 2);
    }

    function testGrantConsentBySigAfterRevocation() public {
        _grant(company, PURPOSE, expiresAt);
        _revoke(company, PURPOSE);
        assertFalse(manager.hasValidConsent(DATASET_ID, company, PURPOSE));

        _grant(company, PURPOSE, expiresAt);

        assertTrue(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
        assertEq(manager.getConsent(DATASET_ID, company, PURPOSE).revokedAt, 0);
    }

    function testFuzzGrantConsentBySig(address grantee, bytes32 purpose, uint64 consentExpiresAt) public {
        vm.assume(grantee != address(0));
        vm.assume(purpose != bytes32(0));
        consentExpiresAt = uint64(bound(consentExpiresAt, block.timestamp + 1, type(uint64).max));

        _grant(grantee, purpose, consentExpiresAt);

        assertTrue(manager.hasValidConsent(DATASET_ID, grantee, purpose));
        assertEq(manager.getConsent(DATASET_ID, grantee, purpose).expiresAt, consentExpiresAt);
    }

    function testRevertWhenGrantToZeroAddress() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, address(0), PURPOSE, expiresAt, 0, deadline);

        vm.expectRevert(ConsentManager.InvalidGrantee.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, address(0), PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGrantWithEmptyPurpose() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, bytes32(0), expiresAt, 0, deadline);

        vm.expectRevert(ConsentManager.EmptyPurpose.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, bytes32(0), expiresAt, deadline, signature);
    }

    function testRevertWhenGrantExpiresNow() public {
        uint64 now64 = uint64(block.timestamp);
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, now64, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.InvalidExpiry.selector, now64));
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, now64, deadline, signature);
    }

    function testRevertWhenGrantForUnknownDataset() public {
        bytes memory signature = _signGrant(clientKey, 2, company, PURPOSE, expiresAt, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.DatasetNotActive.selector, 2));
        vm.prank(relayer);
        manager.grantConsentBySig(2, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGrantForDeletedDataset() public {
        registry.setActive(DATASET_ID, false);
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.DatasetNotActive.selector, DATASET_ID));
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGrantAfterDeadline() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.SignatureExpired.selector, deadline));
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGrantWithForgedSignature() public {
        bytes memory signature = _signGrant(attackerKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.InvalidSigner.selector, attacker, client));
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGranteeSignsOwnConsent() public {
        bytes memory signature = _signGrant(companyKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.InvalidSigner.selector, company, client));
        vm.prank(company);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGrantSignatureIsReplayed() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
        _revoke(company, PURPOSE);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGrantWithTamperedFields() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, attacker, PURPOSE, expiresAt, deadline, signature);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, OTHER_PURPOSE, expiresAt, deadline, signature);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt + 1, deadline, signature);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline + 1, signature);

        assertFalse(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
    }

    function testRevertWhenGrantSignatureIsFromAnotherChain() public {
        bytes memory signature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 0, deadline);
        vm.chainId(block.chainid + 1);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testRevertWhenGrantSignatureIsForAnotherManager() public {
        ConsentManager otherManager = new ConsentManager(address(registry));
        bytes32 structHash =
            keccak256(abi.encode(GRANT_TYPEHASH, DATASET_ID, company, PURPOSE, expiresAt, uint256(0), deadline));
        bytes memory signature = _sign(clientKey, address(otherManager), structHash);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, signature);
    }

    function testGrantFollowsDatasetOwner() public {
        DatasetRegistryMock otherRegistry = new DatasetRegistryMock();
        otherRegistry.setDataset(DATASET_ID, attacker, true);
        ConsentManager otherManager = new ConsentManager(address(otherRegistry));
        bytes32 structHash =
            keccak256(abi.encode(GRANT_TYPEHASH, DATASET_ID, company, PURPOSE, expiresAt, uint256(0), deadline));
        bytes memory clientSignature = _sign(clientKey, address(otherManager), structHash);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.InvalidSigner.selector, client, attacker));
        vm.prank(relayer);
        otherManager.grantConsentBySig(DATASET_ID, company, PURPOSE, expiresAt, deadline, clientSignature);
    }

    function testHasValidConsentUntilExpiry() public {
        _grant(company, PURPOSE, expiresAt);

        vm.warp(expiresAt - 1);
        assertTrue(manager.hasValidConsent(DATASET_ID, company, PURPOSE));

        vm.warp(expiresAt);
        assertFalse(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
    }

    function testHasValidConsentIsFalseAfterDatasetDeletion() public {
        _grant(company, PURPOSE, expiresAt);

        registry.setActive(DATASET_ID, false);

        assertFalse(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
    }

    function testHasValidConsentIsScopedToGranteeAndPurpose() public {
        _grant(company, PURPOSE, expiresAt);

        assertTrue(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
        assertFalse(manager.hasValidConsent(DATASET_ID, attacker, PURPOSE));
        assertFalse(manager.hasValidConsent(DATASET_ID, company, OTHER_PURPOSE));
        assertFalse(manager.hasValidConsent(2, company, PURPOSE));
    }

    function testFuzzHasValidConsentRespectsExpiry(uint64 consentExpiresAt, uint64 checkedAt) public {
        consentExpiresAt = uint64(bound(consentExpiresAt, block.timestamp + 1, type(uint64).max));
        checkedAt = uint64(bound(checkedAt, block.timestamp, type(uint64).max));
        _grant(company, PURPOSE, consentExpiresAt);

        vm.warp(checkedAt);

        assertEq(manager.hasValidConsent(DATASET_ID, company, PURPOSE), checkedAt < consentExpiresAt);
    }

    function testRevokeConsentBySig() public {
        _grant(company, PURPOSE, expiresAt);
        vm.warp(block.timestamp + 1 days);
        bytes memory signature = _signRevoke(clientKey, DATASET_ID, company, PURPOSE, 1, deadline + 1 days);

        vm.expectEmit(true, true, true, true, address(manager));
        emit ConsentManager.ConsentRevoked(DATASET_ID, company, PURPOSE);

        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline + 1 days, signature);

        assertFalse(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
        assertEq(manager.nonces(client), 2);

        Consent memory consent = manager.getConsent(DATASET_ID, company, PURPOSE);
        assertEq(consent.revokedAt, block.timestamp);
        assertEq(consent.expiresAt, expiresAt);
    }

    function testRevokeExpiredConsent() public {
        _grant(company, PURPOSE, expiresAt);
        vm.warp(expiresAt + 1);
        deadline = block.timestamp + 1 hours;

        _revoke(company, PURPOSE);

        assertEq(manager.getConsent(DATASET_ID, company, PURPOSE).revokedAt, block.timestamp);
    }

    function testRevokeConsentOfDeletedDataset() public {
        _grant(company, PURPOSE, expiresAt);
        registry.setActive(DATASET_ID, false);

        _revoke(company, PURPOSE);

        assertEq(manager.getConsent(DATASET_ID, company, PURPOSE).revokedAt, block.timestamp);
    }

    function testRevertWhenRevokeUnknownConsent() public {
        bytes32 consentId = manager.getConsentId(DATASET_ID, company, PURPOSE);
        bytes memory signature = _signRevoke(clientKey, DATASET_ID, company, PURPOSE, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.ConsentNotFound.selector, consentId));
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, signature);
    }

    function testRevertWhenRevokeRevokedConsent() public {
        bytes32 consentId = _grant(company, PURPOSE, expiresAt);
        _revoke(company, PURPOSE);
        bytes memory signature = _signRevoke(clientKey, DATASET_ID, company, PURPOSE, 2, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.ConsentAlreadyRevoked.selector, consentId));
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, signature);
    }

    function testRevertWhenRevokeAfterDeadline() public {
        _grant(company, PURPOSE, expiresAt);
        bytes memory signature = _signRevoke(clientKey, DATASET_ID, company, PURPOSE, 1, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.SignatureExpired.selector, deadline));
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, signature);
    }

    function testRevertWhenRevokeWithForgedSignature() public {
        _grant(company, PURPOSE, expiresAt);
        bytes memory signature = _signRevoke(companyKey, DATASET_ID, company, PURPOSE, 1, deadline);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.InvalidSigner.selector, company, client));
        vm.prank(company);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, signature);
    }

    function testRevertWhenRevokeSignatureIsReplayed() public {
        _grant(company, PURPOSE, expiresAt);
        bytes memory signature = _signRevoke(clientKey, DATASET_ID, company, PURPOSE, 1, deadline);
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, signature);
        _grant(company, PURPOSE, expiresAt);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, signature);

        assertTrue(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
    }

    function testRevertWhenGrantSignatureIsUsedToRevoke() public {
        _grant(company, PURPOSE, expiresAt);
        bytes memory grantSignature = _signGrant(clientKey, DATASET_ID, company, PURPOSE, expiresAt, 1, deadline);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, grantSignature);
    }

    function testGrantAndRevokeShareOwnerNonce() public {
        _grant(company, PURPOSE, expiresAt);
        bytes memory staleSignature = _signRevoke(clientKey, DATASET_ID, company, PURPOSE, 0, deadline);

        vm.expectPartialRevert(ConsentManager.InvalidSigner.selector);
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, company, PURPOSE, deadline, staleSignature);

        _revoke(company, PURPOSE);
        assertEq(manager.nonces(client), 2);
    }

    function testConsentsAreIndependent() public {
        _grant(company, PURPOSE, expiresAt);
        _grant(company, OTHER_PURPOSE, expiresAt);
        _grant(attacker, PURPOSE, expiresAt);

        _revoke(company, PURPOSE);

        assertFalse(manager.hasValidConsent(DATASET_ID, company, PURPOSE));
        assertTrue(manager.hasValidConsent(DATASET_ID, company, OTHER_PURPOSE));
        assertTrue(manager.hasValidConsent(DATASET_ID, attacker, PURPOSE));
    }

    function testRevertWhenGetUnknownConsent() public {
        bytes32 consentId = manager.getConsentId(DATASET_ID, company, PURPOSE);

        vm.expectRevert(abi.encodeWithSelector(ConsentManager.ConsentNotFound.selector, consentId));
        manager.getConsent(DATASET_ID, company, PURPOSE);
    }
}
