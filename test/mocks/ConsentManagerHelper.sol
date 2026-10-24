// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConsentManager} from "../../src/ConsentManager.sol";
import {DatasetRegistryMock} from "./DatasetRegistryMock.sol";

/**
 * @title ConsentManagerHelper
 * @notice Shared setup for ConsentManager tests: a client who owns a dataset in the registry mock, a company
 *         that receives consents, signing of client messages and calls submitted through the relayer.
 */
abstract contract ConsentManagerHelper is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant GRANT_TYPEHASH = keccak256(
        "GrantConsent(uint256 datasetId,address grantee,bytes32 purpose,uint64 expiresAt,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant REVOKE_TYPEHASH =
        keccak256("RevokeConsent(uint256 datasetId,address grantee,bytes32 purpose,uint256 nonce,uint256 deadline)");

    uint256 internal constant DATASET_ID = 1;
    bytes32 internal constant PURPOSE = keccak256("train model X v1");
    bytes32 internal constant OTHER_PURPOSE = keccak256("train model X v2");

    ConsentManager internal manager;
    DatasetRegistryMock internal registry;

    address internal client;
    uint256 internal clientKey;
    address internal company;
    uint256 internal companyKey;
    address internal attacker;
    uint256 internal attackerKey;
    address internal relayer;

    uint256 internal deadline;
    uint64 internal expiresAt;

    function setUp() public {
        (client, clientKey) = makeAddrAndKey("client");
        (company, companyKey) = makeAddrAndKey("company");
        (attacker, attackerKey) = makeAddrAndKey("attacker");
        relayer = makeAddr("relayer");

        registry = new DatasetRegistryMock();
        registry.setDataset(DATASET_ID, client, true);
        manager = new ConsentManager(address(registry));

        deadline = block.timestamp + 1 hours;
        expiresAt = uint64(block.timestamp + 30 days);
    }

    function _grant(address grantee, bytes32 purpose, uint64 consentExpiresAt) internal returns (bytes32 consentId) {
        bytes memory signature =
            _signGrant(clientKey, DATASET_ID, grantee, purpose, consentExpiresAt, manager.nonces(client), deadline);
        vm.prank(relayer);
        return manager.grantConsentBySig(DATASET_ID, grantee, purpose, consentExpiresAt, deadline, signature);
    }

    function _revoke(address grantee, bytes32 purpose) internal {
        bytes memory signature = _signRevoke(clientKey, DATASET_ID, grantee, purpose, manager.nonces(client), deadline);
        vm.prank(relayer);
        manager.revokeConsentBySig(DATASET_ID, grantee, purpose, deadline, signature);
    }

    function _signGrant(
        uint256 signerKey,
        uint256 datasetId,
        address grantee,
        bytes32 purpose,
        uint64 consentExpiresAt,
        uint256 nonce,
        uint256 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(GRANT_TYPEHASH, datasetId, grantee, purpose, consentExpiresAt, nonce, signatureDeadline)
        );
        return _sign(signerKey, address(manager), structHash);
    }

    function _signRevoke(
        uint256 signerKey,
        uint256 datasetId,
        address grantee,
        bytes32 purpose,
        uint256 nonce,
        uint256 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(REVOKE_TYPEHASH, datasetId, grantee, purpose, nonce, signatureDeadline));
        return _sign(signerKey, address(manager), structHash);
    }

    function _sign(uint256 signerKey, address verifyingContract, bytes32 structHash)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(verifyingContract, structHash));
        return abi.encodePacked(r, s, v);
    }

    function _digest(address verifyingContract, bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("ConsentManager"), keccak256("1"), block.chainid, verifyingContract)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
