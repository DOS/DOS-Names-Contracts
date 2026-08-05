// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Script} from "forge-std/Script.sol";

import {GatewayProvider} from "@ens/contracts/ccipRead/GatewayProvider.sol";
import {HexUtils} from "@ens/contracts/utils/HexUtils.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {DOSRegistrar} from "~src/registrar/DOSRegistrar.sol";
import {
    DiscountPoint,
    PaymentRatio,
    StandardRentPriceOracle
} from "~src/registrar/StandardRentPriceOracle.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {L2ReverseRegistrar} from "~src/reverse-registrar/L2ReverseRegistrar.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {ContractNamer} from "~src/utils/ContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {UniversalResolverV2} from "~src/universalResolver/UniversalResolverV2.sol";

/// @title Deploy DOS Name Service
/// @notice Deploys a greenfield ENSv2 stack configured for the `.dos` namespace.
contract DeployDOS is Script, ERC1155Holder {
    address internal constant DEFAULT_WDOS = 0x1111111111111111111111111111111111111111;
    uint64 internal constant MAX_EXPIRY = type(uint64).max;
    uint64 internal constant GRACE_PERIOD = 28 days;
    uint64 internal constant MIN_COMMITMENT_AGE = 60;
    uint64 internal constant MAX_COMMITMENT_AGE = 1 days;
    uint64 internal constant MIN_REGISTER_DURATION = 28 days;
    uint256 internal constant PRICE_SCALE = 1e12;
    uint256 internal constant SEC_PER_YEAR = 365 days;

    /// @notice Payment token decimals cannot represent the oracle price scale.
    /// @param decimals Token decimals reported by the ERC20 contract.
    error PaymentTokenDecimalsTooLow(uint8 decimals);

    /// @notice Payment token decimals exceed the oracle ratio capacity.
    /// @param decimals Token decimals reported by the ERC20 contract.
    error PaymentTokenDecimalsTooHigh(uint8 decimals);

    /// @notice Contracts produced by the DOS deployment profile.
    struct Deployment {
        ContractNamer contractNamer;
        VerifiableFactory verifiableFactory;
        LabelStore labelStore;
        PermissionedRegistry rootRegistry;
        PermissionedRegistry dosRegistry;
        PermissionedRegistry reverseRegistry;
        StandardRentPriceOracle priceOracle;
        DOSRegistrar dosRegistrar;
        PermissionedResolver permissionedResolverImplementation;
        UserRegistry userRegistryImplementation;
        GatewayProvider gatewayProvider;
        UniversalResolverV2 universalResolver;
        L2ReverseRegistrar reverseRegistrar;
    }

    /// @notice Broadcasts a DOS Name Service deployment using environment configuration.
    /// @dev Required env: `PRIVATE_KEY`. Optional env: `BENEFICIARY`, `PAYMENT_TOKEN`.
    /// @return deployment The deployed contract set.
    function run() external virtual returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address beneficiary = vm.envOr("BENEFICIARY", deployer);
        address paymentToken = vm.envOr("PAYMENT_TOKEN", DEFAULT_WDOS);

        vm.startBroadcast(privateKey);
        deployment = deploy(deployer, beneficiary, IERC20(paymentToken), block.chainid);
        vm.stopBroadcast();
    }

    /// @notice Deploys and wires the complete `.dos` contract set.
    /// @param owner Account that controls registry, registrar and pricing administration.
    /// @param beneficiary Account that receives registration and renewal payments.
    /// @param paymentToken ERC20 token accepted by the fixed-price oracle.
    /// @param chainId DOS Chain ID used to derive the ENSIP-19 reverse namespace.
    /// @return deployment The deployed contract set.
    function deploy(address owner, address beneficiary, IERC20 paymentToken, uint256 chainId)
        public
        returns (Deployment memory deployment)
    {
        ContractNamer namerImplementation = new ContractNamer();
        deployment.contractNamer = ContractNamer(
            address(
                new ERC1967Proxy(
                    address(namerImplementation),
                    abi.encodeCall(ContractNamer.initialize, (owner))
                )
            )
        );
        deployment.verifiableFactory = new VerifiableFactory();
        deployment.labelStore = new LabelStore(deployment.contractNamer);

        deployment.rootRegistry = new PermissionedRegistry(
            deployment.labelStore,
            owner,
            _rootRegistryRoles()
        );
        deployment.dosRegistry = new PermissionedRegistry(
            deployment.labelStore,
            owner,
            _dosRegistryRoles()
        );
        deployment.reverseRegistry = new PermissionedRegistry(
            deployment.labelStore,
            owner,
            _rootRegistryRoles()
        );

        deployment.rootRegistry.register(
            "dos",
            owner,
            deployment.dosRegistry,
            address(0),
            _tldTokenRoles(),
            MAX_EXPIRY
        );
        deployment.dosRegistry.setParent(deployment.rootRegistry, "dos");

        deployment.rootRegistry.register(
            "reverse",
            owner,
            deployment.reverseRegistry,
            address(0),
            _tldTokenRoles(),
            MAX_EXPIRY
        );
        deployment.reverseRegistry.setParent(deployment.rootRegistry, "reverse");

        deployment.priceOracle = _deployPriceOracle(owner, paymentToken);
        deployment.dosRegistrar = new DOSRegistrar(
            owner,
            deployment.dosRegistry,
            beneficiary,
            deployment.priceOracle,
            GRACE_PERIOD,
            MIN_COMMITMENT_AGE,
            MAX_COMMITMENT_AGE,
            MIN_REGISTER_DURATION
        );
        deployment.dosRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(deployment.dosRegistrar)
        );

        deployment.permissionedResolverImplementation = new PermissionedResolver(owner);
        deployment.userRegistryImplementation = new UserRegistry(deployment.labelStore, owner);

        string[] memory gateways = new string[](0);
        deployment.gatewayProvider = new GatewayProvider(owner, gateways);
        deployment.universalResolver = new UniversalResolverV2(
            deployment.rootRegistry,
            deployment.gatewayProvider,
            deployment.contractNamer
        );

        uint256 coinType = (1 << 31) | chainId;
        string memory reverseLabel = HexUtils.unpaddedUintToHex(coinType, true);
        deployment.reverseRegistrar = new L2ReverseRegistrar(chainId, reverseLabel);
        deployment.reverseRegistry.register(
            reverseLabel,
            owner,
            IRegistry(address(0)),
            address(deployment.reverseRegistrar),
            0,
            MAX_EXPIRY
        );
    }

    function _deployPriceOracle(address owner, IERC20 paymentToken)
        internal
        returns (StandardRentPriceOracle oracle)
    {
        uint256[] memory baseRates = new uint256[](3);
        baseRates[0] = _yearlyRate(100);
        baseRates[1] = _yearlyRate(50);
        baseRates[2] = _yearlyRate(10);

        DiscountPoint[] memory discounts = new DiscountPoint[](0);
        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        uint8 decimals = IERC20Metadata(address(paymentToken)).decimals();
        if (decimals < 12) {
            revert PaymentTokenDecimalsTooLow(decimals);
        }
        if (decimals > 50) {
            revert PaymentTokenDecimalsTooHigh(decimals);
        }
        uint256 scale = 10 ** (decimals - 12);
        paymentRatios[0] = PaymentRatio({paymentToken: paymentToken, numer: uint128(scale), denom: 1});

        oracle = new StandardRentPriceOracle(owner, baseRates, discounts, 0, 0, 0, 0, paymentRatios);
    }

    function _yearlyRate(uint256 yearlyPrice) internal pure returns (uint256) {
        return (PRICE_SCALE * yearlyPrice + SEC_PER_YEAR - 1) / SEC_PER_YEAR;
    }

    function _rootRegistryRoles() internal pure returns (uint256) {
        return
            RegistryRolesLib.ROLE_REGISTRAR |
            RegistryRolesLib.ROLE_REGISTRAR_ADMIN |
            RegistryRolesLib.ROLE_REGISTER_RESERVED |
            RegistryRolesLib.ROLE_REGISTER_RESERVED_ADMIN |
            RegistryRolesLib.ROLE_SET_PARENT |
            RegistryRolesLib.ROLE_SET_PARENT_ADMIN |
            RegistryRolesLib.ROLE_RENEW |
            RegistryRolesLib.ROLE_RENEW_ADMIN |
            RegistryRolesLib.ROLE_CAN_NAME |
            RegistryRolesLib.ROLE_CAN_NAME_ADMIN |
            RegistryRolesLib.ROLE_SET_URI |
            RegistryRolesLib.ROLE_SET_URI_ADMIN;
    }

    function _dosRegistryRoles() internal pure returns (uint256) {
        return
            RegistryRolesLib.ROLE_REGISTRAR_ADMIN |
            RegistryRolesLib.ROLE_REGISTER_RESERVED_ADMIN |
            RegistryRolesLib.ROLE_SET_PARENT |
            RegistryRolesLib.ROLE_SET_PARENT_ADMIN |
            RegistryRolesLib.ROLE_RENEW_ADMIN |
            RegistryRolesLib.ROLE_CAN_NAME |
            RegistryRolesLib.ROLE_CAN_NAME_ADMIN |
            RegistryRolesLib.ROLE_SET_URI |
            RegistryRolesLib.ROLE_SET_URI_ADMIN;
    }

    function _tldTokenRoles() internal pure virtual returns (uint256) {
        return
            RegistryRolesLib.ROLE_SET_SUBREGISTRY |
            RegistryRolesLib.ROLE_SET_SUBREGISTRY_ADMIN |
            RegistryRolesLib.ROLE_SET_RESOLVER |
            RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN;
    }
}
