// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {DeployDOS} from "./DeployDOS.s.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {
    DEFAULT_ROLE_BITMAP,
    StandardRentPriceOracle
} from "~src/registrar/StandardRentPriceOracle.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";
import {WrappedDOS} from "~src/testnet/WrappedDOS.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @title Deploy DOS Name Service on testnet
/// @notice Deploys a standard wrapped-native WDOS token and the complete `.dos` ENSv2 stack.
contract DeployDOSTestnet is DeployDOS {
    uint256 internal constant EXPECTED_CHAIN_ID = 3939;
    address internal constant EXPECTED_DEPLOYER = 0x310Bc061214ee89aF5CfB28a6ebF96c5436fa3CD;
    address internal constant EXPECTED_OWNER = 0x310Bc061214ee89aF5CfB28a6ebF96c5436fa3CD;
    uint256 internal constant MIN_DEPLOYMENT_BALANCE = 1 ether;
    string internal constant BENS_SMOKE_LABEL = "bens-smoke";
    string internal constant BENS_SMOKE_NAME = "bens-smoke.dos";
    uint64 internal constant BENS_SMOKE_LIFETIME = 10 * 365 days;

    error UnexpectedChain(uint256 actual, uint256 expected);
    error UnexpectedDeployer(address actual, address expected);
    error UnexpectedOwner(address actual, address expected);
    error UnexpectedBeneficiary(address actual, address expected);
    error InsufficientDeploymentBalance(uint256 actual, uint256 required);

    /// @notice Contracts produced by the DOS testnet deployment profile.
    struct TestnetDeployment {
        WrappedDOS wdos;
        Deployment names;
    }

    /// @notice Broadcasts a testnet deployment using environment configuration.
    /// @dev Required env: `PRIVATE_KEY`, `OWNER`. Optional env: `BENEFICIARY`.
    function run() external virtual override returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address beneficiary = vm.envOr("BENEFICIARY", owner);
        address broadcaster = vm.addr(privateKey);

        preflight(broadcaster, owner, beneficiary);
        vm.startBroadcast(privateKey);
        TestnetDeployment memory testnetDeployment =
            deployTestnet(broadcaster, owner, beneficiary, block.chainid);
        vm.stopBroadcast();

        deployment = testnetDeployment.names;
    }

    /// @notice Fails before broadcasting if the Testnet deployment configuration is not canonical.
    function preflight(address broadcaster, address owner, address beneficiary) public view {
        if (block.chainid != EXPECTED_CHAIN_ID) {
            revert UnexpectedChain(block.chainid, EXPECTED_CHAIN_ID);
        }
        if (broadcaster != EXPECTED_DEPLOYER) {
            revert UnexpectedDeployer(broadcaster, EXPECTED_DEPLOYER);
        }
        if (owner != EXPECTED_OWNER) {
            revert UnexpectedOwner(owner, EXPECTED_OWNER);
        }
        if (beneficiary != EXPECTED_OWNER) {
            revert UnexpectedBeneficiary(beneficiary, EXPECTED_OWNER);
        }
        if (broadcaster.balance < MIN_DEPLOYMENT_BALANCE) {
            revert InsufficientDeploymentBalance(broadcaster.balance, MIN_DEPLOYMENT_BALANCE);
        }
    }

    /// @notice Deploys WDOS and wires it into a DOS Name Service deployment.
    /// @param initialOwner Account broadcasting deployment and temporary wiring calls.
    /// @param owner Final protocol administrator.
    function deployTestnet(address initialOwner, address owner, address beneficiary, uint256 chainId)
        public
        returns (TestnetDeployment memory deployment)
    {
        deployment.wdos = new WrappedDOS();
        deployment.names = deploy(
            initialOwner,
            beneficiary,
            IERC20(address(deployment.wdos)),
            chainId
        );
        _registerBensSmokeName(deployment.names, initialOwner, owner, chainId);
        _handoff(deployment.names, initialOwner, owner);
    }

    /// @dev Creates one stable forward and reverse record used by Graph Node and BENS acceptance gates.
    function _registerBensSmokeName(
        Deployment memory deployment,
        address initialOwner,
        address owner,
        uint256 chainId
    )
        internal
    {
        bytes[] memory setters = new bytes[](0);
        PermissionedResolver resolver =
            PermissionedResolver(
                deployment.verifiableFactory.deployProxy(
                    address(deployment.permissionedResolverImplementation),
                    1,
                    abi.encodeCall(
                        PermissionedResolver.initialize,
                        (initialOwner, EACBaseRolesLib.ALL_ROLES, setters)
                    )
                )
            );
        bytes32 node = NameCoder.namehash(NameCoder.encode(BENS_SMOKE_NAME), 0);

        PermissionedRegistry registry = deployment.dosRegistry;
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, initialOwner);
        registry.register(
            BENS_SMOKE_LABEL,
            owner,
            IRegistry(address(0)),
            address(resolver),
            0,
            uint64(block.timestamp + BENS_SMOKE_LIFETIME)
        );
        registry.revokeRootRoles(RegistryRolesLib.ROLE_REGISTRAR, initialOwner);

        // Resolver records must be emitted after ResolverUpdated creates the
        // dynamic Graph Node source. Dynamic sources cannot replay prior logs.
        resolver.setAddr(node, initialOwner);
        resolver.setAddr(node, (1 << 31) | chainId, abi.encodePacked(initialOwner));

        deployment.reverseRegistrar.setName(BENS_SMOKE_NAME);
        resolver.grantRootRoles(EACBaseRolesLib.ALL_ROLES, owner);
        resolver.revokeRootRoles(EACBaseRolesLib.ALL_ROLES, initialOwner);
    }

    function _handoff(Deployment memory deployment, address initialOwner, address owner) internal {
        if (owner == initialOwner) {
            return;
        }

        _handoffTld(deployment.rootRegistry, initialOwner, owner, "dos");
        _handoffTld(deployment.rootRegistry, initialOwner, owner, "reverse");
        _handoffRoles(deployment.rootRegistry, initialOwner, owner, _rootRegistryRoles());
        _handoffRoles(deployment.dosRegistry, initialOwner, owner, _dosRegistryRoles());
        _handoffRoles(deployment.reverseRegistry, initialOwner, owner, _rootRegistryRoles());
        _handoffRoles(deployment.priceOracle, initialOwner, owner, DEFAULT_ROLE_BITMAP);
        _handoffRoles(
            deployment.permissionedResolverImplementation,
            initialOwner,
            owner,
            PermissionedResolverLib.ROLE_CAN_NAME | PermissionedResolverLib.ROLE_CAN_NAME_ADMIN
        );
        _handoffRoles(
            deployment.userRegistryImplementation,
            initialOwner,
            owner,
            RegistryRolesLib.ROLE_CAN_NAME | RegistryRolesLib.ROLE_CAN_NAME_ADMIN
        );

        deployment.contractNamer.transferOwnership(owner);
        deployment.gatewayProvider.transferOwnership(owner);
        deployment.dosRegistrar.transferOwnership(owner);
    }

    function _handoffTld(
        PermissionedRegistry registry,
        address initialOwner,
        address owner,
        string memory label
    )
        internal
    {
        uint256 tokenId = registry.getTokenId(LibLabel.id(label));
        registry.safeTransferFrom(initialOwner, owner, tokenId, 1, "");
    }

    function _handoffRoles(
        PermissionedRegistry registry,
        address initialOwner,
        address owner,
        uint256 roles
    )
        internal
    {
        registry.grantRootRoles(roles, owner);
        registry.revokeRootRoles(roles, initialOwner);
    }

    function _handoffRoles(
        StandardRentPriceOracle oracle,
        address initialOwner,
        address owner,
        uint256 roles
    )
        internal
    {
        oracle.grantRootRoles(roles, owner);
        oracle.revokeRootRoles(roles, initialOwner);
    }

    function _handoffRoles(
        PermissionedResolver resolver,
        address initialOwner,
        address owner,
        uint256 roles
    )
        internal
    {
        resolver.grantRootRoles(roles, owner);
        resolver.revokeRootRoles(roles, initialOwner);
    }

    function _tldTokenRoles() internal pure override returns (uint256) {
        return super._tldTokenRoles() | RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
    }
}
