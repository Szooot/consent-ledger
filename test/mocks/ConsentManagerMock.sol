// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.28;

import {IConsentManager} from "../../src/interfaces/IConsentManager.sol";
import {Consent} from "../../src/types/ConsentTypes.sol";

/**
 * @title ConsentManagerMock
 * @notice Stand-in for ConsentManager whose consent validity is set directly by the test, without signatures.
 */
contract ConsentManagerMock is IConsentManager {
    error NotImplemented();

    mapping(bytes32 consentId => bool valid) private _valid;

    function setValidConsent(uint256 datasetId, address grantee, bytes32 purpose, bool valid) external {
        _valid[getConsentId(datasetId, grantee, purpose)] = valid;
    }

    function grantConsentBySig(uint256, address, bytes32, uint64, uint256, bytes calldata)
        external
        pure
        returns (bytes32)
    {
        revert NotImplemented();
    }

    function revokeConsentBySig(uint256, address, bytes32, uint256, bytes calldata) external pure {
        revert NotImplemented();
    }

    function hasValidConsent(uint256 datasetId, address grantee, bytes32 purpose) external view returns (bool) {
        return _valid[getConsentId(datasetId, grantee, purpose)];
    }

    function getConsent(uint256, address, bytes32) external pure returns (Consent memory) {
        revert NotImplemented();
    }

    function getConsentId(uint256 datasetId, address grantee, bytes32 purpose) public pure returns (bytes32) {
        return keccak256(abi.encode(datasetId, grantee, purpose));
    }

    function getDatasetRegistry() external pure returns (address) {
        revert NotImplemented();
    }
}
