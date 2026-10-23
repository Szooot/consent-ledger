// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Kind of personal data a dataset holds. Values 1-3 are special categories under GDPR Art. 9.
 * @dev 0 Other, 1 Medical, 2 Genetic, 3 Biometric, 4 Financial, 5 Location, 6 Behavioral,
 *      7 Communication, 8 Demographic, 9 Employment, 10 Education.
 */
enum Category {
    Other,
    Medical,
    Genetic,
    Biometric,
    Financial,
    Location,
    Behavioral,
    Communication,
    Demographic,
    Employment,
    Education
}

/**
 * @notice A registered dataset.
 * @param owner Address of the data owner.
 * @param createdAt Block timestamp of the registration.
 * @param category Kind of data in the dataset.
 * @param active False once the owner deletes the dataset.
 * @param cidDigest SHA-256 digest from the IPFS CID of the encrypted file.
 */
struct Dataset {
    address owner;
    uint64 createdAt;
    Category category;
    bool active;
    bytes32 cidDigest;
}
