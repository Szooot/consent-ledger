// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IConsentManager} from "./interfaces/IConsentManager.sol";
import {IUsageLog} from "./interfaces/IUsageLog.sol";

/**
 * @title UsageLog
 * @notice Record of every use of a dataset: who used it, for what purpose and with what evidence.
 * @dev Only addresses with LOGGER_ROLE, e.g. the key service, can record a use, and only while the consent in
 *      ConsentManager is valid. Each piece of evidence can be recorded once. The admin only manages loggers and
 *      can hand the admin role over only after a delay.
 */
contract UsageLog is IUsageLog, AccessControlDefaultAdminRules {
    /**
     * @notice Role allowed to record uses.
     * @dev Value: 0x566c814873eed56a69b28c40ab27cc2cb150d74068bae3e884ccd44f8de60f8a
     */
    bytes32 public constant LOGGER_ROLE = keccak256("LOGGER_ROLE");

    /**
     * @notice Address of the ConsentManager contract the consents are checked in.
     */
    IConsentManager private immutable CONSENT_MANAGER_CONTRACT;

    /**
     * @notice Number of recorded uses by consent id.
     */
    mapping(bytes32 consentId => uint256 count) private _usageCounts;

    /**
     * @notice Whether a piece of evidence was recorded.
     */
    mapping(bytes32 evidenceHash => bool logged) private _loggedEvidence;

    /**
     * @notice Emitted when a use of a dataset is recorded.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient that used the dataset.
     * @param purpose Hash of the purpose text.
     * @param evidenceHash Hash of the evidence of the use.
     */
    event DataUsed(uint256 indexed datasetId, address indexed grantee, bytes32 indexed purpose, bytes32 evidenceHash);

    /**
     * @notice The consent manager address is zero.
     * @dev Selector: 0xd37a39e5
     */
    error InvalidConsentManager();

    /**
     * @notice The logger address is zero.
     * @dev Selector: 0x7b747b50
     */
    error InvalidLogger();

    /**
     * @notice The evidence hash is zero.
     * @dev Selector: 0xcb3a13f7
     */
    error EmptyEvidence();

    /**
     * @notice A use with this evidence was already recorded.
     * @dev Selector: 0x2bbf006b
     * @param evidenceHash Hash of the evidence.
     */
    error EvidenceAlreadyLogged(bytes32 evidenceHash);

    /**
     * @notice The grantee has no valid consent to use the dataset for this purpose.
     * @dev Selector: 0xd9d687ce
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     */
    error NoValidConsent(uint256 datasetId, address grantee, bytes32 purpose);

    /**
     * @notice Sets the consent manager, the admin with the delay for handing the admin role over and the first
     *         logger.
     * @param consentManager Address of the ConsentManager contract.
     * @param adminDelay Seconds a new admin has to wait before taking the admin role over.
     * @param admin Address of the admin.
     * @param logger Address allowed to record uses, e.g. the key service.
     */
    constructor(address consentManager, uint48 adminDelay, address admin, address logger)
        AccessControlDefaultAdminRules(adminDelay, admin)
    {
        if (consentManager == address(0)) revert InvalidConsentManager();
        if (logger == address(0)) revert InvalidLogger();
        CONSENT_MANAGER_CONTRACT = IConsentManager(consentManager);
        _grantRole(LOGGER_ROLE, logger);
    }

    /**
     * @notice Records that `grantee` used the dataset for `purpose`. Callable only by a logger, e.g. the key
     *         service when it hands out a dataset key, and only while the consent is valid.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient that used the dataset.
     * @param purpose Hash of the purpose text.
     * @param evidenceHash Hash of the evidence of the use kept off-chain, e.g. the id of the handed-out key.
     */
    function logUsage(uint256 datasetId, address grantee, bytes32 purpose, bytes32 evidenceHash)
        external
        onlyRole(LOGGER_ROLE)
    {
        if (evidenceHash == bytes32(0)) revert EmptyEvidence();
        if (_loggedEvidence[evidenceHash]) revert EvidenceAlreadyLogged(evidenceHash);
        if (!CONSENT_MANAGER_CONTRACT.hasValidConsent(datasetId, grantee, purpose)) {
            revert NoValidConsent(datasetId, grantee, purpose);
        }

        _loggedEvidence[evidenceHash] = true;
        ++_usageCounts[CONSENT_MANAGER_CONTRACT.getConsentId(datasetId, grantee, purpose)];

        emit DataUsed(datasetId, grantee, purpose, evidenceHash);
    }

    /**
     * @notice Returns how many uses were recorded for a dataset, grantee and purpose.
     * @param datasetId Id of the dataset.
     * @param grantee Address of the recipient.
     * @param purpose Hash of the purpose text.
     * @return Number of recorded uses.
     */
    function getUsageCount(uint256 datasetId, address grantee, bytes32 purpose) external view returns (uint256) {
        return _usageCounts[CONSENT_MANAGER_CONTRACT.getConsentId(datasetId, grantee, purpose)];
    }

    /**
     * @notice Tells whether a use with this evidence was recorded.
     * @param evidenceHash Hash of the evidence of the use.
     * @return True if the evidence was recorded.
     */
    function isEvidenceLogged(bytes32 evidenceHash) external view returns (bool) {
        return _loggedEvidence[evidenceHash];
    }

    /**
     * @notice Returns the address of the ConsentManager contract the consents are checked in.
     * @return Address of the ConsentManager contract.
     */
    function getConsentManager() external view returns (address) {
        return address(CONSENT_MANAGER_CONTRACT);
    }
}
