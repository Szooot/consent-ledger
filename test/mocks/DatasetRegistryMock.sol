// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {IDatasetRegistry} from "../../src/interfaces/IDatasetRegistry.sol";
import {Category, Dataset} from "../../src/types/DatasetTypes.sol";

/**
 * @title DatasetRegistryMock
 * @notice Stand-in for DatasetRegistry whose datasets are set directly by the test, without signatures.
 */
contract DatasetRegistryMock is IDatasetRegistry {
    error DatasetNotFound(uint256 datasetId);
    error NotImplemented();

    mapping(uint256 datasetId => Dataset dataset) private _datasets;
    uint256 private _datasetCount;

    function setDataset(uint256 datasetId, address owner, bool active) external {
        _datasets[datasetId] = Dataset({
            owner: owner,
            createdAt: uint64(block.timestamp),
            category: Category.Other,
            active: active,
            cidDigest: keccak256(abi.encode(datasetId))
        });
        if (datasetId > _datasetCount) _datasetCount = datasetId;
    }

    function setActive(uint256 datasetId, bool active) external {
        _datasets[datasetId].active = active;
    }

    function registerDatasetBySig(address, bytes32, Category, uint256, bytes calldata) external pure returns (uint256) {
        revert NotImplemented();
    }

    function updateDatasetBySig(uint256, bytes32, uint256, bytes calldata) external pure {
        revert NotImplemented();
    }

    function deleteDatasetBySig(uint256, uint256, bytes calldata) external pure {
        revert NotImplemented();
    }

    function getDatasetCount() external view returns (uint256) {
        return _datasetCount;
    }

    function getDataset(uint256 datasetId) external view returns (Dataset memory) {
        Dataset memory dataset = _datasets[datasetId];
        if (dataset.owner == address(0)) revert DatasetNotFound(datasetId);
        return dataset;
    }

    function getOwnerOfDataset(uint256 datasetId) external view returns (address) {
        address owner = _datasets[datasetId].owner;
        if (owner == address(0)) revert DatasetNotFound(datasetId);
        return owner;
    }

    function isActive(uint256 datasetId) external view returns (bool) {
        return _datasets[datasetId].active;
    }
}
