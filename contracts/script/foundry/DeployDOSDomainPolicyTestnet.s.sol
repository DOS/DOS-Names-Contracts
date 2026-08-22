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
/// @dev Required env: PRIVATE_KEY (the canonical registry owner), DOS_DOMAIN_VOUCHER_SIGNER,
/// DOS_DOMAIN_REGISTRY, DOS_DOMAIN_PRICE_ORACLE, and DOS_DOMAIN_LEGACY_REGISTRAR.
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

    /// @notice Existing DOS Name contracts and policy configuration for this deployment.
    struct DeploymentConfig {
        PermissionedRegistry registry;
        StandardRentPriceOracle priceOracle;
        address legacyRegistrar;
        address voucherSigner;
        uint32 minimumScore;
        address defaultResolver;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Expected DOS Testnet chain ID.
    uint256 internal constant EXPECTED_CHAIN_ID = 3939;

    /// @dev Account that owns the deployed registry roles.
    address internal constant EXPECTED_OWNER = 0x310Bc061214ee89aF5CfB28a6ebF96c5436fa3CD;

    /// @dev Renewable period after a name expires.
    uint64 internal constant GRACE_PERIOD = 28 days;

    /// @dev Minimum age required before a commitment can register.
    uint64 internal constant MIN_COMMITMENT_AGE = 60;

    /// @dev Maximum age at which a commitment remains valid.
    uint64 internal constant MAX_COMMITMENT_AGE = 1 days;

    /// @dev Shortest duration permitted by the registrar.
    uint64 internal constant MIN_REGISTER_DURATION = 28 days;

    /// @dev Root roles moved from the legacy registrar to the policy registrar.
    uint256 internal constant REGISTRAR_ROLES = RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW;

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
        DeploymentConfig memory config = deploymentConfig();
        preflight(vm.addr(privateKey), config);

        vm.startBroadcast(privateKey);
        deployment.policy = deployPolicy(config);
        deployment.registrar = deployRegistrar(config, deployment.policy);
        config.registry.revokeRootRoles(REGISTRAR_ROLES, config.legacyRegistrar);
        config.registry.grantRootRoles(REGISTRAR_ROLES, address(deployment.registrar));
        deployment.policy.setRegistrar(deployment.registrar);
        vm.stopBroadcast();
    }

    /// @notice Reads and validates the runtime-specific contract configuration.
    function deploymentConfig() internal view returns (DeploymentConfig memory config) {
        uint256 configuredMinimumScore = vm.envOr("DOS_DOMAIN_MINIMUM_SCORE", uint256(20));
        if (configuredMinimumScore > type(uint32).max) {
            revert InvalidMinimumScore(configuredMinimumScore);
        }

        config = DeploymentConfig({
            registry: PermissionedRegistry(vm.envAddress("DOS_DOMAIN_REGISTRY")),
            priceOracle: StandardRentPriceOracle(vm.envAddress("DOS_DOMAIN_PRICE_ORACLE")),
            legacyRegistrar: vm.envAddress("DOS_DOMAIN_LEGACY_REGISTRAR"),
            voucherSigner: vm.envAddress("DOS_DOMAIN_VOUCHER_SIGNER"),
            minimumScore: uint32(configuredMinimumScore),
            defaultResolver: vm.envOr("DOS_DOMAIN_DEFAULT_RESOLVER", address(0))
        });
    }

    /// @notice Deploys the score-gated policy contract.
    function deployPolicy(DeploymentConfig memory config) internal returns (DosDomainPolicy) {
        return new DosDomainPolicy(
            config.registry, EXPECTED_OWNER, config.voucherSigner, config.minimumScore, config.defaultResolver
        );
    }

    /// @notice Deploys the registrar that enforces the policy contract.
    function deployRegistrar(DeploymentConfig memory config, DosDomainPolicy policy)
        internal
        returns (DOSPolicyRegistrar)
    {
        return new DOSPolicyRegistrar(
            EXPECTED_OWNER,
            config.registry,
            EXPECTED_OWNER,
            config.priceOracle,
            GRACE_PERIOD,
            MIN_COMMITMENT_AGE,
            MAX_COMMITMENT_AGE,
            MIN_REGISTER_DURATION,
            address(policy)
        );
    }

    /// @notice Validates network, broadcaster, existing contracts, and legacy registrar roles before deployment.
    /// @param broadcaster The address derived from the transaction private key.
    function preflight(address broadcaster, DeploymentConfig memory config) internal view {
        if (block.chainid != EXPECTED_CHAIN_ID) {
            revert UnexpectedChain(block.chainid, EXPECTED_CHAIN_ID);
        }
        if (broadcaster != EXPECTED_OWNER) {
            revert UnexpectedOwner(broadcaster, EXPECTED_OWNER);
        }
        if (address(config.registry).code.length == 0) {
            revert MissingContractCode(address(config.registry));
        }
        if (address(config.priceOracle).code.length == 0) {
            revert MissingContractCode(address(config.priceOracle));
        }
        if (config.legacyRegistrar.code.length == 0) {
            revert MissingContractCode(config.legacyRegistrar);
        }
        if (!config.registry.hasRootRoles(REGISTRAR_ROLES, config.legacyRegistrar)) {
            revert LegacyRegistrarAlreadyRetired(config.legacyRegistrar);
        }
    }
}
