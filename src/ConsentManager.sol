// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IConsentManager} from "./interfaces/IConsentManager.sol";
import {IDatasetRegistry} from "./interfaces/IDatasetRegistry.sol";
import {Consent} from "./types/ConsentTypes.sol";

/**
 * @title ConsentManager
 * @notice Consents to use a dataset: who may use it, for what purpose and until when.
 * @dev A consent is identified by the dataset, the grantee and the purpose. Only the dataset owner from
 *      DatasetRegistry can grant or revoke it, always through a signature, so the owner never pays gas.
 *      A signature works only once, only in this contract and only before its deadline.
 */
contract ConsentManager is IConsentManager, EIP712, Nonces {
    /**
     * @notice Type hash of the GrantConsent message signed by the dataset owner.
     * @dev Value: 0xab9656da2de541730fd687c4fcbb07b839699e936a8b9eacdb4aff3223907c41
     */
    bytes32 public constant GRANT_TYPEHASH = keccak256(
        "GrantConsent(uint256 datasetId,address grantee,bytes32 purpose,uint64 expiresAt,uint256 nonce,uint256 deadline)"
    );

    /**
     * @notice Type hash of the RevokeConsent message signed by the dataset owner.
     * @dev Value: 0x966469dc9b4c06c732814dded949ded7276bdfe69d6e6fd6379000584d7b7432
     */
    bytes32 public constant REVOKE_TYPEHASH =
        keccak256("RevokeConsent(uint256 datasetId,address grantee,bytes32 purpose,uint256 nonce,uint256 deadline)");

    /**
     * @notice Address of the DatasetRegistry contract the datasets and their owners are read from.
     */
    IDatasetRegistry private immutable DATASET_REGISTRY_CONTRACT;

    /**
     * @notice Consent records by consent id.
     */
    mapping(bytes32 consentId => Consent consent) private _consents;

    /**
     * @notice Emitted when the owner grants or renews a consent.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @param expiresAt Timestamp from which the consent is no longer valid.
     */
    event ConsentGranted(uint256 indexed datasetId, address indexed grantee, bytes32 indexed purpose, uint64 expiresAt);

    /**
     * @notice Emitted when the owner revokes a consent.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     */
    event ConsentRevoked(uint256 indexed datasetId, address indexed grantee, bytes32 indexed purpose);

    /**
     * @notice The dataset registry address is zero.
     * @dev Selector: 0xa1a49707
     */
    error InvalidDatasetRegistry();

    /**
     * @notice The grantee address is zero.
     * @dev Selector: 0xe8146ac4
     */
    error InvalidGrantee();

    /**
     * @notice The purpose hash is zero.
     * @dev Selector: 0xdfa03e50
     */
    error EmptyPurpose();

    /**
     * @notice The expiry isn't in the future.
     * @dev Selector: 0x5e23ca68
     * @param expiresAt Requested expiry.
     */
    error InvalidExpiry(uint64 expiresAt);

    /**
     * @notice The dataset doesn't exist or was deleted.
     * @dev Selector: 0x92d8621b
     * @param datasetId Id of the dataset.
     */
    error DatasetNotActive(uint256 datasetId);

    /**
     * @notice No consent was ever granted for this dataset, grantee and purpose.
     * @dev Selector: 0xddae8389
     * @param consentId Id of the consent.
     */
    error ConsentNotFound(bytes32 consentId);

    /**
     * @notice The consent is already revoked.
     * @dev Selector: 0xbad9cfbe
     * @param consentId Id of the consent.
     */
    error ConsentAlreadyRevoked(bytes32 consentId);

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
     * @notice Sets the dataset registry and the name and version of the messages owners sign:
     *         "ConsentManager", "1".
     * @param datasetRegistry Address of the DatasetRegistry contract.
     */
    constructor(address datasetRegistry) EIP712("ConsentManager", "1") {
        if (datasetRegistry == address(0)) revert InvalidDatasetRegistry();
        DATASET_REGISTRY_CONTRACT = IDatasetRegistry(datasetRegistry);
    }

    /**
     * @notice Grants `grantee` consent to use the dataset for `purpose` until `expiresAt`. The dataset owner
     *         signs a GrantConsent message and anyone can submit it. Granting again replaces the previous
     *         consent for the same dataset, grantee and purpose, including a revoked one.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient, e.g. an AI company.
     * @param purpose Hash of the purpose text, e.g. keccak256("train model X v1").
     * @param expiresAt Timestamp from which the consent is no longer valid.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature over the GrantConsent message.
     * @return consentId Id of the consent.
     */
    function grantConsentBySig(
        uint256 datasetId,
        address grantee,
        bytes32 purpose,
        uint64 expiresAt,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32 consentId) {
        if (grantee == address(0)) revert InvalidGrantee();
        if (purpose == bytes32(0)) revert EmptyPurpose();
        // solhint-disable-next-line gas-strict-inequalities
        if (expiresAt <= block.timestamp) revert InvalidExpiry(expiresAt); // forge-lint: disable-line(block-timestamp)
        if (!DATASET_REGISTRY_CONTRACT.isActive(datasetId)) revert DatasetNotActive(datasetId);

        address owner = DATASET_REGISTRY_CONTRACT.getOwnerOfDataset(datasetId);
        bytes32 structHash =
            keccak256(abi.encode(GRANT_TYPEHASH, datasetId, grantee, purpose, expiresAt, _useNonce(owner), deadline));
        _verifySignature(owner, structHash, deadline, signature);

        consentId = _consentId(datasetId, grantee, purpose);
        _consents[consentId] =
            Consent({grantedAt: SafeCast.toUint64(block.timestamp), expiresAt: expiresAt, revokedAt: 0});

        /// forge-lint: disable-next-line(reentrancy-events)
        emit ConsentGranted(datasetId, grantee, purpose, expiresAt);
    }

    /**
     * @notice Revokes the consent. The dataset owner signs a RevokeConsent message and anyone can submit it.
     *         The record stays for the audit trail.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @param deadline Timestamp after which the signature is no longer accepted.
     * @param signature Owner's signature over the RevokeConsent message.
     */
    function revokeConsentBySig(
        uint256 datasetId,
        address grantee,
        bytes32 purpose,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 consentId = _consentId(datasetId, grantee, purpose);
        Consent storage consent = _consents[consentId];
        if (consent.grantedAt == 0) revert ConsentNotFound(consentId);
        if (consent.revokedAt != 0) revert ConsentAlreadyRevoked(consentId);

        address owner = DATASET_REGISTRY_CONTRACT.getOwnerOfDataset(datasetId);
        bytes32 structHash =
            keccak256(abi.encode(REVOKE_TYPEHASH, datasetId, grantee, purpose, _useNonce(owner), deadline));
        _verifySignature(owner, structHash, deadline, signature);

        consent.revokedAt = SafeCast.toUint64(block.timestamp);

        /// forge-lint: disable-next-line(reentrancy-events)
        emit ConsentRevoked(datasetId, grantee, purpose);
    }

    /**
     * @notice Tells whether `grantee` may use the dataset for `purpose` right now.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return True if the consent was granted, isn't revoked, hasn't expired and the dataset is active.
     */
    function hasValidConsent(uint256 datasetId, address grantee, bytes32 purpose) external view returns (bool) {
        Consent memory consent = _consents[_consentId(datasetId, grantee, purpose)];
        // solhint-disable-next-line gas-strict-inequalities
        if (consent.revokedAt != 0 || block.timestamp >= consent.expiresAt) return false; // forge-lint: disable-line(block-timestamp)
        return DATASET_REGISTRY_CONTRACT.isActive(datasetId);
    }

    /**
     * @notice Returns the consent record.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return The consent record.
     */
    function getConsent(uint256 datasetId, address grantee, bytes32 purpose) external view returns (Consent memory) {
        bytes32 consentId = _consentId(datasetId, grantee, purpose);
        Consent memory consent = _consents[consentId];
        if (consent.grantedAt == 0) revert ConsentNotFound(consentId);
        return consent;
    }

    /**
     * @notice Returns the id of the consent for a dataset, grantee and purpose.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return keccak256 of the three values.
     */
    function getConsentId(uint256 datasetId, address grantee, bytes32 purpose) external pure returns (bytes32) {
        return _consentId(datasetId, grantee, purpose);
    }

    /**
     * @notice Returns the address of the DatasetRegistry contract the datasets are read from.
     * @return Address of the DatasetRegistry contract.
     */
    function getDatasetRegistry() external view returns (address) {
        return address(DATASET_REGISTRY_CONTRACT);
    }

    /**
     * @notice Computes the id of the consent for a dataset, grantee and purpose.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return keccak256 of the three values.
     */
    function _consentId(uint256 datasetId, address grantee, bytes32 purpose) private pure returns (bytes32) {
        return keccak256(abi.encode(datasetId, grantee, purpose));
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
