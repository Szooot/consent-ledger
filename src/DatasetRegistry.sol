// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDatasetRegistry} from "./interfaces/IDatasetRegistry.sol";
import {Category, Dataset} from "./types/DatasetTypes.sol";

/**
 * @title DatasetRegistry
 * @notice Registry of encrypted datasets: who owns a dataset, which file it points to and what kind of data
 *         it holds. The data itself never touches the chain.
 * @dev The owner's address doubles as their DID: did:ethr:<network>:<address>. Every change is authorized by
 *      the owner's signature, so the owner never pays gas. A signature works only once, only in this contract
 *      and only before its deadline.
 */
contract DatasetRegistry is IDatasetRegistry, EIP712, Nonces {
    /**
     * @notice Type hash of the RegisterDataset message signed by the owner.
     * @dev Value: 0x15abb05752770e3fa9cc0426152827e86f33d5a650a1684b2ec8723f3a2ffe06
     */
    bytes32 public constant REGISTER_TYPEHASH =
        keccak256("RegisterDataset(address owner,bytes32 cidDigest,uint8 category,uint256 nonce,uint256 deadline)");

    /**
     * @notice Type hash of the UpdateDataset message signed by the owner.
     * @dev Value: 0xf909b0974db1b2232b2d24e7bcc9e0623174f31b3583a41c9c10745e6c12cacb
     */
    bytes32 public constant UPDATE_TYPEHASH =
        keccak256("UpdateDataset(uint256 datasetId,bytes32 cidDigest,uint256 nonce,uint256 deadline)");

    /**
     * @notice Type hash of the DeleteDataset message signed by the owner.
     * @dev Value: 0x54aabc30f1343210573b2ddec1c5a38fcd3bd3ab1d0d9d66b6be7fcd37d8b16f
     */
    bytes32 public constant DELETE_TYPEHASH =
        keccak256("DeleteDataset(uint256 datasetId,uint256 nonce,uint256 deadline)");

    /**
     * @notice Number of datasets registered so far; also the id of the most recent one.
     */
    uint256 private _datasetCount;

    /**
     * @notice Dataset records by id. Ids start at 1.
     */
    mapping(uint256 datasetId => Dataset dataset) private _datasets;

    /**
     * @notice Emitted when a dataset is registered.
     * @param datasetId Id of the new dataset.
     * @param owner Address of the data owner.
     * @param category Kind of data in the dataset.
     * @param cidDigest SHA-256 digest from the IPFS CID.
     */
    event DatasetRegistered(
        uint256 indexed datasetId, address indexed owner, Category indexed category, bytes32 cidDigest
    );

    /**
     * @notice Emitted when the owner points a dataset to a new file.
     * @param datasetId Id of the dataset.
     * @param cidDigest New SHA-256 digest from the IPFS CID.
     */
    event DatasetUpdated(uint256 indexed datasetId, bytes32 cidDigest);

    /**
     * @notice Emitted when the owner deletes a dataset.
     * @param datasetId Id of the dataset.
     */
    event DatasetDeleted(uint256 indexed datasetId);

    /**
     * @notice The CID digest is zero.
     * @dev Selector: 0x1fa647e1
     */
    error EmptyCidDigest();

    /**
     * @notice No dataset has this id.
     * @dev Selector: 0xbb36834d
     * @param datasetId Requested id.
     */
    error DatasetNotFound(uint256 datasetId);

    /**
     * @notice The dataset was deleted.
     * @dev Selector: 0x92d8621b
     * @param datasetId Id of the dataset.
     */
    error DatasetNotActive(uint256 datasetId);

    /**
     * @notice The signature's deadline has passed.
     * @dev Selector: 0xcd21db4f
     * @param deadline Deadline included in the signed message.
     */
    error SignatureExpired(uint256 deadline);

    /**
     * @notice The signature wasn't made by the dataset owner.
     * @dev Selector: 0x7ba5ffb5
     * @param signer Address recovered from the signature.
     * @param owner Address of the dataset owner.
     */
    error InvalidSigner(address signer, address owner);

    /**
     * @notice Sets the name and version of the messages owners sign: "DatasetRegistry", "1".
     */
    constructor() EIP712("DatasetRegistry", "1") {}

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
    ) external returns (uint256 datasetId) {
        if (cidDigest == bytes32(0)) revert EmptyCidDigest();

        bytes32 structHash =
            keccak256(abi.encode(REGISTER_TYPEHASH, owner, cidDigest, category, _useNonce(owner), deadline));
        _verifySignature(owner, structHash, deadline, signature);

        datasetId = ++_datasetCount;
        _datasets[datasetId] = Dataset({
            owner: owner,
            createdAt: SafeCast.toUint64(block.timestamp),
            category: category,
            active: true,
            cidDigest: cidDigest
        });

        /// forge-lint: disable-next-line(reentrancy-events)
        emit DatasetRegistered(datasetId, owner, category, cidDigest);
    }

    /**
     * @notice Points the dataset to a new file, e.g. after re-encryption with a new key. The owner signs an
     *         UpdateDataset message and anyone can submit it.
     * @param datasetId Id of the dataset.
     * @param cidDigest New SHA-256 digest from the IPFS CID.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature over the UpdateDataset message.
     */
    function updateDatasetBySig(uint256 datasetId, bytes32 cidDigest, uint256 deadline, bytes calldata signature)
        external
    {
        if (cidDigest == bytes32(0)) revert EmptyCidDigest();
        address owner = _activeOwner(datasetId);

        bytes32 structHash = keccak256(abi.encode(UPDATE_TYPEHASH, datasetId, cidDigest, _useNonce(owner), deadline));
        _verifySignature(owner, structHash, deadline, signature);

        _datasets[datasetId].cidDigest = cidDigest;

        /// forge-lint: disable-next-line(reentrancy-events)
        emit DatasetUpdated(datasetId, cidDigest);
    }

    /**
     * @notice Deactivates the dataset. The owner signs a DeleteDataset message and anyone can
     *         submit it. The record stays for the audit trail, but no new consent can be granted for it and
     *         existing consents stop being valid.
     * @param datasetId Id of the dataset.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature over the DeleteDataset message.
     */
    function deleteDatasetBySig(uint256 datasetId, uint256 deadline, bytes calldata signature) external {
        address owner = _activeOwner(datasetId);

        bytes32 structHash = keccak256(abi.encode(DELETE_TYPEHASH, datasetId, _useNonce(owner), deadline));
        _verifySignature(owner, structHash, deadline, signature);

        _datasets[datasetId].active = false;

        /// forge-lint: disable-next-line(reentrancy-events)
        emit DatasetDeleted(datasetId);
    }

    /**
     * @notice Returns the number of datasets registered so far; also the id of the most recent one.
     * @return Number of registered datasets.
     */
    function getDatasetCount() external view returns (uint256) {
        return _datasetCount;
    }

    /**
     * @notice Returns the full dataset record.
     * @param datasetId Id of the dataset.
     * @return The dataset record.
     */
    function getDataset(uint256 datasetId) external view returns (Dataset memory) {
        Dataset memory dataset = _datasets[datasetId];
        if (dataset.owner == address(0)) revert DatasetNotFound(datasetId);
        return dataset;
    }

    /**
     * @notice Returns the owner of the dataset.
     * @param datasetId Id of the dataset.
     * @return Address of the data owner.
     */
    function getOwnerOfDataset(uint256 datasetId) external view returns (address) {
        address owner = _datasets[datasetId].owner;
        if (owner == address(0)) revert DatasetNotFound(datasetId);
        return owner;
    }

    /**
     * @notice Tells whether the dataset exists and wasn't deleted.
     * @param datasetId Id of the dataset.
     * @return False for deleted and for never-registered datasets.
     */
    function isActive(uint256 datasetId) external view returns (bool) {
        return _datasets[datasetId].active;
    }

    /**
     * @notice Returns the owner of an existing, active dataset.
     * @param datasetId Id of the dataset.
     * @return owner Address of the data owner.
     */
    function _activeOwner(uint256 datasetId) private view returns (address owner) {
        Dataset storage dataset = _datasets[datasetId];
        owner = dataset.owner;
        if (owner == address(0)) revert DatasetNotFound(datasetId);
        if (!dataset.active) revert DatasetNotActive(datasetId);
    }

    /**
     * @notice Checks that the signature is still valid and was made by `owner`.
     * @param owner Address expected to have signed the message.
     * @param structHash Hash of the signed message, including the owner's nonce.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature.
     */
    function _verifySignature(address owner, bytes32 structHash, uint256 deadline, bytes calldata signature)
        private
        view
    {
        /// forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != owner) revert InvalidSigner(signer, owner);
    }
}
