// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DatasetRegistry} from "../../src/DatasetRegistry.sol";
import {Category} from "../../src/types/DatasetTypes.sol";

/**
 * @title DatasetRegistryHelper
 * @notice Shared setup for DatasetRegistry tests: actors, signing of client messages and calls submitted
 *         through the relayer.
 */
abstract contract DatasetRegistryHelper is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant REGISTER_TYPEHASH =
        keccak256("RegisterDataset(address owner,bytes32 cidDigest,uint8 category,uint256 nonce,uint256 deadline)");
    bytes32 internal constant UPDATE_TYPEHASH =
        keccak256("UpdateDataset(uint256 datasetId,bytes32 cidDigest,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DELETE_TYPEHASH =
        keccak256("DeleteDataset(uint256 datasetId,uint256 nonce,uint256 deadline)");

    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    bytes32 internal constant CID_DIGEST = keccak256("encrypted-file-1");
    bytes32 internal constant NEW_CID_DIGEST = keccak256("encrypted-file-2");

    DatasetRegistry internal registry;

    address internal client;
    uint256 internal clientKey;
    address internal attacker;
    uint256 internal attackerKey;
    address internal relayer;

    uint256 internal deadline;

    function setUp() public {
        registry = new DatasetRegistry();
        (client, clientKey) = makeAddrAndKey("client");
        (attacker, attackerKey) = makeAddrAndKey("attacker");
        relayer = makeAddr("relayer");
        deadline = block.timestamp + 1 hours;
    }

    function _register(bytes32 cidDigest, Category category) internal returns (uint256 datasetId) {
        return _registerAs(clientKey, client, cidDigest, category);
    }

    function _registerAs(uint256 ownerKey, address owner, bytes32 cidDigest, Category category)
        internal
        returns (uint256 datasetId)
    {
        bytes memory signature = _signRegister(ownerKey, owner, cidDigest, category, registry.nonces(owner), deadline);
        vm.prank(relayer);
        return registry.registerDatasetBySig(owner, cidDigest, category, deadline, signature);
    }

    function _delete(uint256 datasetId, uint256 nonce) internal {
        bytes memory signature = _signDelete(clientKey, datasetId, nonce, deadline);
        vm.prank(relayer);
        registry.deleteDatasetBySig(datasetId, deadline, signature);
    }

    function _signRegister(
        uint256 signerKey,
        address owner,
        bytes32 cidDigest,
        Category category,
        uint256 nonce,
        uint256 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(REGISTER_TYPEHASH, owner, cidDigest, category, nonce, signatureDeadline)
        );
        return _sign(signerKey, address(registry), structHash);
    }

    function _signUpdate(
        uint256 signerKey,
        uint256 datasetId,
        bytes32 cidDigest,
        uint256 nonce,
        uint256 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(UPDATE_TYPEHASH, datasetId, cidDigest, nonce, signatureDeadline));
        return _sign(signerKey, address(registry), structHash);
    }

    function _signDelete(uint256 signerKey, uint256 datasetId, uint256 nonce, uint256 signatureDeadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(DELETE_TYPEHASH, datasetId, nonce, signatureDeadline));
        return _sign(signerKey, address(registry), structHash);
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
            abi.encode(DOMAIN_TYPEHASH, keccak256("DatasetRegistry"), keccak256("1"), block.chainid, verifyingContract)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
