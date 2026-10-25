// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IUsageLog
 * @notice Record of every use of a dataset: who used it, for what purpose and with what evidence.
 */
interface IUsageLog {
    /**
     * @notice Records that `grantee` used the dataset for `purpose`. Callable only by a logger, e.g. the key
     *         service when it hands out a dataset key, and only while the consent is valid.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient that used the dataset.
     * @param purpose Hash of the purpose text.
     * @param evidenceHash Hash of the evidence of the use kept off-chain, e.g. the id of the handed-out key.
     */
    function logUsage(uint256 datasetId, address grantee, bytes32 purpose, bytes32 evidenceHash) external;

    /**
     * @notice Returns how many uses were recorded for a dataset, grantee and purpose.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return Number of recorded uses.
     */
    function getUsageCount(uint256 datasetId, address grantee, bytes32 purpose) external view returns (uint256);

    /**
     * @notice Tells whether a use with this evidence was recorded.
     * @param evidenceHash Hash of the evidence of the use.
     * @return True if the evidence was recorded.
     */
    function isEvidenceLogged(bytes32 evidenceHash) external view returns (bool);

    /**
     * @notice Returns the address of the ConsentManager contract the consents are checked in.
     * @return Address of the ConsentManager contract.
     */
    function getConsentManager() external view returns (address);
}
