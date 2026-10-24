// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice A consent given by a dataset owner to one recipient for one purpose.
 * @param grantedAt Block timestamp of the latest grant; zero while the consent isn't granted.
 * @param expiresAt Timestamp from which the consent is no longer valid; zero while the consent isn't granted.
 * @param revokedAt Block timestamp of the revocation; zero while the consent isn't revoked.
 */
struct Consent {
    uint64 grantedAt;
    uint64 expiresAt;
    uint64 revokedAt;
}

