// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {DatasetRegistry} from "../src/DatasetRegistry.sol";
import {Category, Dataset} from "../src/types/DatasetTypes.sol";
import {DatasetRegistryHelper} from "./mocks/DatasetRegistryHelper.sol";

/**
 * @title DatasetRegistryTest
 * @notice Functional and security tests for DatasetRegistry. Clients only sign messages; a relayer submits
 *         every transaction.
 */
contract DatasetRegistryTest is DatasetRegistryHelper {
    function testTypeHashes() public view {
        assertEq(registry.REGISTER_TYPEHASH(), REGISTER_TYPEHASH);
        assertEq(registry.UPDATE_TYPEHASH(), UPDATE_TYPEHASH);
        assertEq(registry.DELETE_TYPEHASH(), DELETE_TYPEHASH);
    }

    function testSigningDomain() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            registry.eip712Domain();
        assertEq(name, "DatasetRegistry");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(registry));
    }

    function testInitialState() public view {
        assertEq(registry.getDatasetCount(), 0);
        assertFalse(registry.isActive(1));
        assertEq(registry.nonces(client), 0);
    }

    function testRegisterDatasetBySig() public {
        bytes memory signature = _signRegister(clientKey, client, CID_DIGEST, Category.Medical, 0, deadline);

        vm.expectEmit(true, true, true, true, address(registry));
        emit DatasetRegistry.DatasetRegistered(1, client, Category.Medical, CID_DIGEST);

        vm.prank(relayer);
        uint256 datasetId = registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);

        assertEq(datasetId, 1);
        assertEq(registry.getDatasetCount(), 1);
        assertEq(registry.nonces(client), 1);
        assertTrue(registry.isActive(datasetId));
        assertEq(registry.getOwnerOfDataset(datasetId), client);

        Dataset memory dataset = registry.getDataset(datasetId);
        assertEq(dataset.owner, client);
        assertEq(dataset.createdAt, block.timestamp);
        assertEq(uint8(dataset.category), uint8(Category.Medical));
        assertTrue(dataset.active);
        assertEq(dataset.cidDigest, CID_DIGEST);
    }

    function testRegisterDatasetBySigAssignsSequentialIds() public {
        assertEq(_register(CID_DIGEST, Category.Medical), 1);
        assertEq(_register(NEW_CID_DIGEST, Category.Financial), 2);
        assertEq(registry.getDatasetCount(), 2);
        assertEq(registry.nonces(client), 2);
    }

    function testRegisterDatasetBySigAcceptsDeadlineEqualToNow() public {
        bytes memory signature = _signRegister(clientKey, client, CID_DIGEST, Category.Other, 0, block.timestamp);

        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Other, block.timestamp, signature);

        assertEq(registry.getDatasetCount(), 1);
    }

    function testFuzzRegisterDatasetBySig(bytes32 cidDigest, uint8 categoryIndex) public {
        vm.assume(cidDigest != bytes32(0));
        Category category = Category(bound(categoryIndex, 0, uint8(type(Category).max)));

        uint256 datasetId = _registerAs(clientKey, client, cidDigest, category);

        Dataset memory dataset = registry.getDataset(datasetId);
        assertEq(dataset.cidDigest, cidDigest);
        assertEq(uint8(dataset.category), uint8(category));
    }

    function testRevertWhenRegisterWithEmptyCidDigest() public {
        bytes memory signature = _signRegister(clientKey, client, bytes32(0), Category.Medical, 0, deadline);

        vm.expectRevert(DatasetRegistry.EmptyCidDigest.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, bytes32(0), Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterAfterDeadline() public {
        bytes memory signature = _signRegister(clientKey, client, CID_DIGEST, Category.Medical, 0, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.SignatureExpired.selector, deadline));
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterWithForgedSignature() public {
        bytes memory signature = _signRegister(attackerKey, client, CID_DIGEST, Category.Medical, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.InvalidSigner.selector, attacker, client));
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterSignatureIsReplayed() public {
        bytes memory signature = _signRegister(clientKey, client, CID_DIGEST, Category.Medical, 0, deadline);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterWithTamperedFields() public {
        bytes memory signature = _signRegister(clientKey, client, CID_DIGEST, Category.Medical, 0, deadline);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, NEW_CID_DIGEST, Category.Medical, deadline, signature);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Financial, deadline, signature);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline + 1, signature);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(attacker, CID_DIGEST, Category.Medical, deadline, signature);

        assertEq(registry.getDatasetCount(), 0);
    }

    function testRevertWhenRegisterSignatureIsFromAnotherChain() public {
        bytes memory signature = _signRegister(clientKey, client, CID_DIGEST, Category.Medical, 0, deadline);
        vm.chainId(block.chainid + 1);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterSignatureIsForAnotherRegistry() public {
        DatasetRegistry otherRegistry = new DatasetRegistry();
        bytes32 structHash =
            keccak256(abi.encode(REGISTER_TYPEHASH, client, CID_DIGEST, Category.Medical, uint256(0), deadline));
        bytes memory signature = _sign(clientKey, address(otherRegistry), structHash);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterWithMalleableSignature() public {
        bytes32 structHash =
            keccak256(abi.encode(REGISTER_TYPEHASH, client, CID_DIGEST, Category.Medical, uint256(0), deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(clientKey, _digest(address(registry), structHash));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        bytes memory signature = abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27));

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterWithWrongSignatureLength() public {
        bytes memory signature = new bytes(64);

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        vm.prank(relayer);
        registry.registerDatasetBySig(client, CID_DIGEST, Category.Medical, deadline, signature);
    }

    function testRevertWhenRegisterWithUnknownCategory() public {
        bytes memory signature = _signRegister(clientKey, client, CID_DIGEST, Category.Other, 0, deadline);
        bytes memory callData = abi.encodeWithSelector(
            DatasetRegistry.registerDatasetBySig.selector,
            client,
            CID_DIGEST,
            uint256(type(Category).max) + 1,
            deadline,
            signature
        );

        vm.prank(relayer);
        (bool success,) = address(registry).call(callData);

        assertFalse(success);
        assertEq(registry.getDatasetCount(), 0);
    }

    function testUpdateDatasetBySig() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signUpdate(clientKey, datasetId, NEW_CID_DIGEST, 1, deadline);

        vm.expectEmit(true, true, true, true, address(registry));
        emit DatasetRegistry.DatasetUpdated(datasetId, NEW_CID_DIGEST);

        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, NEW_CID_DIGEST, deadline, signature);

        Dataset memory dataset = registry.getDataset(datasetId);
        assertEq(dataset.cidDigest, NEW_CID_DIGEST);
        assertEq(dataset.owner, client);
        assertTrue(dataset.active);
        assertEq(registry.nonces(client), 2);
    }

    function testRevertWhenUpdateWithEmptyCidDigest() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signUpdate(clientKey, datasetId, bytes32(0), 1, deadline);

        vm.expectRevert(DatasetRegistry.EmptyCidDigest.selector);
        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, bytes32(0), deadline, signature);
    }

    function testRevertWhenUpdateUnknownDataset() public {
        bytes memory signature = _signUpdate(clientKey, 1, NEW_CID_DIGEST, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.DatasetNotFound.selector, 1));
        vm.prank(relayer);
        registry.updateDatasetBySig(1, NEW_CID_DIGEST, deadline, signature);
    }

    function testRevertWhenUpdateDeletedDataset() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        _delete(datasetId, 1);
        bytes memory signature = _signUpdate(clientKey, datasetId, NEW_CID_DIGEST, 2, deadline);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.DatasetNotActive.selector, datasetId));
        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, NEW_CID_DIGEST, deadline, signature);
    }

    function testRevertWhenUpdateWithForgedSignature() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signUpdate(attackerKey, datasetId, NEW_CID_DIGEST, 1, deadline);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.InvalidSigner.selector, attacker, client));
        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, NEW_CID_DIGEST, deadline, signature);
    }

    function testRevertWhenUpdateAfterDeadline() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signUpdate(clientKey, datasetId, NEW_CID_DIGEST, 1, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.SignatureExpired.selector, deadline));
        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, NEW_CID_DIGEST, deadline, signature);
    }

    function testRevertWhenUpdateSignatureIsReplayed() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signUpdate(clientKey, datasetId, NEW_CID_DIGEST, 1, deadline);
        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, NEW_CID_DIGEST, deadline, signature);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, NEW_CID_DIGEST, deadline, signature);
    }

    function testDeleteDatasetBySig() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signDelete(clientKey, datasetId, 1, deadline);

        vm.expectEmit(true, true, true, true, address(registry));
        emit DatasetRegistry.DatasetDeleted(datasetId);

        vm.prank(relayer);
        registry.deleteDatasetBySig(datasetId, deadline, signature);

        assertFalse(registry.isActive(datasetId));
        assertEq(registry.nonces(client), 2);
        assertEq(registry.getDatasetCount(), 1);

        Dataset memory dataset = registry.getDataset(datasetId);
        assertFalse(dataset.active);
        assertEq(dataset.owner, client);
        assertEq(dataset.cidDigest, CID_DIGEST);
    }

    function testRevertWhenDeleteUnknownDataset() public {
        bytes memory signature = _signDelete(clientKey, 1, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.DatasetNotFound.selector, 1));
        vm.prank(relayer);
        registry.deleteDatasetBySig(1, deadline, signature);
    }

    function testRevertWhenDeleteDeletedDataset() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        _delete(datasetId, 1);
        bytes memory signature = _signDelete(clientKey, datasetId, 2, deadline);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.DatasetNotActive.selector, datasetId));
        vm.prank(relayer);
        registry.deleteDatasetBySig(datasetId, deadline, signature);
    }

    function testRevertWhenDeleteWithForgedSignature() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signDelete(attackerKey, datasetId, 1, deadline);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.InvalidSigner.selector, attacker, client));
        vm.prank(relayer);
        registry.deleteDatasetBySig(datasetId, deadline, signature);
    }

    function testRevertWhenDeleteAfterDeadline() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory signature = _signDelete(clientKey, datasetId, 1, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.SignatureExpired.selector, deadline));
        vm.prank(relayer);
        registry.deleteDatasetBySig(datasetId, deadline, signature);
    }

    function testRevertWhenSignatureIsUsedForAnotherAction() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory updateSignature = _signUpdate(clientKey, datasetId, NEW_CID_DIGEST, 1, deadline);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.deleteDatasetBySig(datasetId, deadline, updateSignature);
    }

    function testActionsShareOwnerNonce() public {
        uint256 datasetId = _register(CID_DIGEST, Category.Medical);
        bytes memory staleSignature = _signDelete(clientKey, datasetId, 0, deadline);

        vm.expectPartialRevert(DatasetRegistry.InvalidSigner.selector);
        vm.prank(relayer);
        registry.deleteDatasetBySig(datasetId, deadline, staleSignature);

        bytes memory updateSignature = _signUpdate(clientKey, datasetId, NEW_CID_DIGEST, 1, deadline);
        vm.prank(relayer);
        registry.updateDatasetBySig(datasetId, NEW_CID_DIGEST, deadline, updateSignature);

        _delete(datasetId, 2);
        assertEq(registry.nonces(client), 3);
    }

    function testOwnersAreIndependent() public {
        uint256 clientDataset = _register(CID_DIGEST, Category.Medical);
        uint256 attackerDataset = _registerAs(attackerKey, attacker, NEW_CID_DIGEST, Category.Location);

        assertEq(registry.getOwnerOfDataset(clientDataset), client);
        assertEq(registry.getOwnerOfDataset(attackerDataset), attacker);
        assertEq(registry.nonces(client), 1);
        assertEq(registry.nonces(attacker), 1);
    }

    function testRevertWhenGetUnknownDataset() public {
        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.DatasetNotFound.selector, 7));
        registry.getDataset(7);
    }

    function testRevertWhenGetOwnerOfUnknownDataset() public {
        vm.expectRevert(abi.encodeWithSelector(DatasetRegistry.DatasetNotFound.selector, 7));
        registry.getOwnerOfDataset(7);
    }
}
