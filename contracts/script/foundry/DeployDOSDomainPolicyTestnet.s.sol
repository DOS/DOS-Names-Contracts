// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script} from "forge-std/Script.sol";

import {DosDomainPolicy} from "~src/registrar/DosDomainPolicy.sol";
import {DOSPolicyRegistrar} from "~src/registrar/DOSPolicyRegistrar.sol";
import {StandardRentPriceOracle} from "~src/registrar/StandardRentPriceOracle.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";

/// @title Deploy DOS ID Domain Policy on DOS Testnet
/// @notice Replaces the public Testnet registrar role with a policy-controlled registrar.
/// @dev Required env: PRIVATE_KEY (the canonical registry owner) and DOS_DOMAIN_VOUCHER_SIGNER.
///      No private voucher key is read by this deployment script.
contract DeployDOSDomainPolicyTestnet is Script {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice Contracts deployed by this policy deployment profile.
    struct Deployment {
        DosDomainPolicy policy;
        DOSPolicyRegistrar registrar;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Expected DOS Testnet chain ID.
    uint256 internal constant EXPECTED_CHAIN_ID = 3939;

    /// @dev Account that owns the deployed registry roles.
    address internal constant EXPECTED_OWNER = 0x310Bc061214ee89aF5CfB28a6ebF96c5436fa3CD;

    /// @dev Existing `.dos` registry address.
    address internal constant DOS_REGISTRY = 0x95366f1E44532F50c022aEefF708F424b7854173;

    /// @dev Existing `.dos` rent price oracle address.
    address internal constant PRICE_ORACLE = 0x2eE958BcF29d140cdf64ad767f32E2554B0CCfa6;

    /// @dev Existing public registrar whose roles are retired by this script.
    address internal constant LEGACY_DOS_REGISTRAR = 0x4E5B48aC8B221aAF8cFF070671CB6Eeea2122b5c;

    /// @dev Renewable period after a name expires.
    uint64 internal constant GRACE_PERIOD = 28 days;

    /// @dev Minimum age required before a commitment can register.
    uint64 internal constant MIN_COMMITMENT_AGE = 60;

    /// @dev Maximum age at which a commitment remains valid.
    uint64 internal constant MAX_COMMITMENT_AGE = 1 days;

    /// @dev Shortest duration permitted by the registrar.
    uint64 internal constant MIN_REGISTER_DURATION = 28 days;

    /// @dev Root roles moved from the legacy registrar to the policy registrar.
    uint256 internal constant REGISTRAR_ROLES =
        RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0xdb2dd806`
    error UnexpectedChain(uint256 actual, uint256 expected);
    /// @dev Error selector: `0x7e9c2f9d`
    error UnexpectedOwner(address actual, address expected);
    /// @dev Error selector: `0x4535258f`
    error MissingContractCode(address target);
    /// @dev Error selector: `0x7f1dd828`
    error LegacyRegistrarAlreadyRetired(address registrar);
    /// @dev Error selector: `0x16319300`
    error InvalidMinimumScore(uint256 value);

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the policy and registrar, then atomically moves registrar roles per transaction.
    /// @dev Policy subsidy funding is intentionally separate: seed it only after address verification.
    /// @return deployment The deployed policy and policy-controlled registrar.
    function run() external returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address voucherSigner = vm.envAddress("DOS_DOMAIN_VOUCHER_SIGNER");
        uint256 configuredMinimumScore = vm.envOr("DOS_DOMAIN_MINIMUM_SCORE", uint256(20));
        address defaultResolver = vm.envOr("DOS_DOMAIN_DEFAULT_RESOLVER", address(0));
        if (configuredMinimumScore > type(uint32).max) {
            revert InvalidMinimumScore(configuredMinimumScore);
        }

        address broadcaster = vm.addr(privateKey);
        preflight(broadcaster);

        PermissionedRegistry registry = PermissionedRegistry(DOS_REGISTRY);
        vm.startBroadcast(privateKey);
        deployment.policy = new DosDomainPolicy(
            registry,
            EXPECTED_OWNER,
            voucherSigner,
            uint32(configuredMinimumScore),
            defaultResolver
        );
        deployment.registrar = new DOSPolicyRegistrar(
            EXPECTED_OWNER,
            registry,
            EXPECTED_OWNER,
            StandardRentPriceOracle(PRICE_ORACLE),
            GRACE_PERIOD,
            MIN_COMMITMENT_AGE,
            MAX_COMMITMENT_AGE,
            MIN_REGISTER_DURATION,
            address(deployment.policy)
        );
        registry.revokeRootRoles(REGISTRAR_ROLES, LEGACY_DOS_REGISTRAR);
        registry.grantRootRoles(REGISTRAR_ROLES, address(deployment.registrar));
        deployment.policy.setRegistrar(deployment.registrar);
        vm.stopBroadcast();
    }

    /// @notice Validates network, broadcaster, existing contracts, and legacy registrar roles before deployment.
    /// @param broadcaster The address derived from the transaction private key.
    function preflight(address broadcaster) public view {
        if (block.chainid != EXPECTED_CHAIN_ID) {
            revert UnexpectedChain(block.chainid, EXPECTED_CHAIN_ID);
        }
        if (broadcaster != EXPECTED_OWNER) {
            revert UnexpectedOwner(broadcaster, EXPECTED_OWNER);
        }
        if (DOS_REGISTRY.code.length == 0) {
            revert MissingContractCode(DOS_REGISTRY);
        }
        if (PRICE_ORACLE.code.length == 0) {
            revert MissingContractCode(PRICE_ORACLE);
        }
        if (LEGACY_DOS_REGISTRAR.code.length == 0) {
            revert MissingContractCode(LEGACY_DOS_REGISTRAR);
        }
        if (!PermissionedRegistry(DOS_REGISTRY).hasRootRoles(REGISTRAR_ROLES, LEGACY_DOS_REGISTRAR)) {
            revert LegacyRegistrarAlreadyRetired(LEGACY_DOS_REGISTRAR);
        }
    }
}
