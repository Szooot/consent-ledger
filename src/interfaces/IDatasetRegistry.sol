// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Category, Dataset} from "../types/DatasetTypes.sol";

/**
 * @title IDatasetRegistry
 * @notice Registry of encrypted datasets: who owns a dataset, which file it points to and what kind of data
 *         it holds. The data itself never touches the chain.
 */
interface IDatasetRegistry {
    /**
     * @notice Registers a dataset on behalf of `owner`, who signed a RegisterDataset message.
     *         Anyone can submit it and pay the gas, so the owner needs no ETH.
     * @param owner Address of the data owner who signed the message.
     * @param cidDigest SHA-256 digest from the IPFS CID of the encrypted file.
     * @param category Kind of data in the dataset.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature over the RegisterDataset message.
     * @return datasetId Id of the new dataset.
     */
    function registerDatasetBySig(
        address owner,
        bytes32 cidDigest,
        Category category,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 datasetId);

    /**
     * @notice Points the dataset to a new file, e.g. after re-encryption with a new key. The owner signs an
     *         UpdateDataset message and anyone can submit it.
     * @param datasetId Id of the dataset.
     * @param cidDigest New SHA-256 digest from the IPFS CID.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature over the UpdateDataset message.
     */
    function updateDatasetBySig(uint256 datasetId, bytes32 cidDigest, uint256 deadline, bytes calldata signature)
        external;

    /**
     * @notice Deactivates the dataset. The owner signs a DeleteDataset message and anyone can
     *         submit it. The record stays for the audit trail, but no new consent can be granted for it and
     *         existing consents stop being valid.
     * @param datasetId Id of the dataset.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature over the DeleteDataset message.
     */
    function deleteDatasetBySig(uint256 datasetId, uint256 deadline, bytes calldata signature) external;

    /**
     * @notice Returns the number of datasets registered so far; also the id of the most recent one.
     * @return Number of registered datasets.
     */
    function getDatasetCount() external view returns (uint256);

    /**
     * @notice Returns the full dataset record.
     * @param datasetId Id of the dataset.
     * @return The dataset record.
     */
    function getDataset(uint256 datasetId) external view returns (Dataset memory);

    /**
     * @notice Returns the owner of the dataset.
     * @param datasetId Id of the dataset.
     * @return Address of the data owner.
     */
    function getOwnerOfDataset(uint256 datasetId) external view returns (address);

    /**
     * @notice Tells whether the dataset exists and wasn't deleted.
     * @param datasetId Id of the dataset.
     * @return False for deleted and for never-registered datasets.
     */
    function isActive(uint256 datasetId) external view returns (bool);
}
