// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IRegistryMetadata} from "~src/registry/interfaces/IRegistryMetadata.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";

import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";
import {SimpleRegistryMetadata} from "~src/registry/SimpleRegistryMetadata.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";

import {StandardRentPriceOracle, DiscountPoint, PaymentRatio} from "~src/registrar/StandardRentPriceOracle.sol";
import {DOSRegistrar} from "~src/registrar/DOSRegistrar.sol";
import {IRentPriceOracle} from "~src/registrar/interfaces/IRentPriceOracle.sol";

import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {UniversalResolverV2} from "~src/universalResolver/UniversalResolverV2.sol";
import {IGatewayProvider} from "@ens/contracts/universalResolver/AbstractUniversalResolver.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";

contract DeployDOS is Script {
    /// @dev WDOS (Wrapped Native Token) on DOS Chain
    address constant WDOS = 0x1111111111111111111111111111111111111111;

    /// @dev Maximum expiry
    uint64 constant MAX_EXPIRY = type(uint64).max;

    // ---- Stored between phases so we stay under the stack limit ----
    IHCAFactoryBasic internal _hcaFactory;
    IRegistryMetadata internal _metadata;
    PermissionedRegistry internal _root;
    PermissionedRegistry internal _dosTLD;
    PermissionedRegistry internal _reverseReg;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        _deployCore(deployer);
        _deployRegistrar(deployer);
        _deployImplementations();

        vm.stopBroadcast();

        console.log("--- Deployment Complete ---");
        console.log("Deployer:", deployer);
    }

    /// @dev Phase 1: HCAFactory, Metadata, Root, DOS TLD, Reverse registries + TLD registrations.
    function _deployCore(address deployer) internal {
        // 1. HCAFactory (mock for testnet)
        MockHCAFactoryBasic hcaFactory = new MockHCAFactoryBasic();
        _hcaFactory = IHCAFactoryBasic(address(hcaFactory));
        console.log("HCAFactory:", address(hcaFactory));

        // 2. SimpleRegistryMetadata
        SimpleRegistryMetadata metadata = new SimpleRegistryMetadata(_hcaFactory);
        _metadata = IRegistryMetadata(address(metadata));
        console.log("SimpleRegistryMetadata:", address(metadata));

        // 3. RootRegistry
        PermissionedRegistry root = new PermissionedRegistry(
            _hcaFactory, _metadata, deployer, EACBaseRolesLib.ALL_ROLES
        );
        _root = root;
        console.log("RootRegistry:", address(root));

        // 4. DOSTLDRegistry
        PermissionedRegistry dosTLD = new PermissionedRegistry(
            _hcaFactory, _metadata, deployer, EACBaseRolesLib.ALL_ROLES
        );
        _dosTLD = dosTLD;
        console.log("DOSTLDRegistry:", address(dosTLD));

        // Register "dos" TLD in root
        root.register("dos", deployer, IRegistry(address(dosTLD)), address(0), 0, MAX_EXPIRY);

        // 5. ReverseRegistry
        PermissionedRegistry reverseReg = new PermissionedRegistry(
            _hcaFactory, _metadata, deployer, EACBaseRolesLib.ALL_ROLES
        );
        _reverseReg = reverseReg;
        console.log("ReverseRegistry:", address(reverseReg));

        // Register "reverse" in root
        root.register("reverse", deployer, IRegistry(address(reverseReg)), address(0), 0, MAX_EXPIRY);
    }

    /// @dev Phase 2: PriceOracle + DOSRegistrar + role grants.
    function _deployRegistrar(address deployer) internal {
        // 6. StandardRentPriceOracle
        uint256[] memory baseRatePerCp = new uint256[](3);
        baseRatePerCp[0] = 3_170_979_198; // 1-char: ~100 DOS/year
        baseRatePerCp[1] = 1_585_489_599; // 2-char: ~50 DOS/year
        baseRatePerCp[2] = 317_097_919;   // 3+ char: ~10 DOS/year

        DiscountPoint[] memory discountPoints = new DiscountPoint[](0);

        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio({token: IERC20(WDOS), numer: 1, denom: 1});

        StandardRentPriceOracle priceOracle = new StandardRentPriceOracle(
            deployer,
            IPermissionedRegistry(address(_dosTLD)),
            baseRatePerCp,
            discountPoints,
            0,  // premiumPriceInitial
            0,  // premiumHalvingPeriod
            0,  // premiumPeriod
            paymentRatios
        );
        console.log("StandardRentPriceOracle:", address(priceOracle));

        // 7. DOSRegistrar
        DOSRegistrar registrar = new DOSRegistrar(
            IPermissionedRegistry(address(_dosTLD)),
            _hcaFactory,
            deployer,   // beneficiary
            60,          // minCommitmentAge (seconds)
            86400,       // maxCommitmentAge (1 day)
            2419200,     // minRegisterDuration (28 days)
            IRentPriceOracle(address(priceOracle))
        );
        console.log("DOSRegistrar:", address(registrar));

        // Grant ROLE_REGISTRAR | ROLE_RENEW to DOSRegistrar on dosTLD
        _dosTLD.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(registrar)
        );
    }

    /// @dev Phase 3: Implementation contracts (UUPS) + UniversalResolver.
    function _deployImplementations() internal {
        // 8. PermissionedResolver implementation
        PermissionedResolver resolverImpl = new PermissionedResolver(_hcaFactory);
        console.log("PermissionedResolver (impl):", address(resolverImpl));

        // 9. UserRegistry implementation
        UserRegistry userRegistryImpl = new UserRegistry(_hcaFactory, _metadata);
        console.log("UserRegistry (impl):", address(userRegistryImpl));

        // 10. UniversalResolverV2
        UniversalResolverV2 universalResolver = new UniversalResolverV2(
            IRegistry(address(_root)),
            IGatewayProvider(address(0)) // no batch gateway for testnet
        );
        console.log("UniversalResolverV2:", address(universalResolver));
    }
}
