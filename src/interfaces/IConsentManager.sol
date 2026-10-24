// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Consent} from "../types/ConsentTypes.sol";

/**
 * @title IConsentManager
 * @notice Consents to use a dataset: who may use it, for what purpose and until when.
 */
interface IConsentManager {
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
    ) external returns (bytes32 consentId);

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
    ) external;

    /**
     * @notice Tells whether `grantee` may use the dataset for `purpose` right now.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return True if the consent was granted, isn't revoked, hasn't expired and the dataset is active.
     */
    function hasValidConsent(uint256 datasetId, address grantee, bytes32 purpose) external view returns (bool);

    /**
     * @notice Returns the consent record.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return The consent record.
     */
    function getConsent(uint256 datasetId, address grantee, bytes32 purpose) external view returns (Consent memory);

    /**
     * @notice Returns the id of the consent for a dataset, grantee and purpose.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return keccak256 of the three values.
     */
    function getConsentId(uint256 datasetId, address grantee, bytes32 purpose) external pure returns (bytes32);

    /**
     * @notice Returns the address of the DatasetRegistry contract the datasets are read from.
     * @return Address of the DatasetRegistry contract.
     */
    function getDatasetRegistry() external view returns (address);
}
