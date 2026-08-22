// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {
    DeployDOSDomainPolicyTestnet
} from "../../../script/foundry/DeployDOSDomainPolicyTestnet.s.sol";

import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {StandardRentPriceOracleFixture} from "~test/fixtures/StandardRentPriceOracleFixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract DeployDOSDomainPolicyTestnetTest is V2Fixture, StandardRentPriceOracleFixture {
    address internal constant EXPECTED_OWNER = 0x310Bc061214ee89aF5CfB28a6ebF96c5436fa3CD;
    uint256 internal constant REGISTRAR_ROLES =
        RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW;
    uint256 internal constant REGISTRAR_ADMIN_ROLES =
        RegistryRolesLib.ROLE_REGISTRAR_ADMIN | RegistryRolesLib.ROLE_RENEW_ADMIN;

    DeployDOSDomainPolicyTestnet internal deployer;

    function setUp() external {
        deployV2Fixture();
        deployStandardRentPriceOracleFixture();
        deployer = new DeployDOSDomainPolicyTestnet();

        vm.chainId(3939);
        vm.deal(EXPECTED_OWNER, 1 ether);
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, address(this));
        ethRegistry.grantRootRoles(REGISTRAR_ADMIN_ROLES, EXPECTED_OWNER);
    }

    function test_preflightAcceptsCanonicalOwnerWithRegistrarAdminRoles() external {
        deployer.preflight(EXPECTED_OWNER, _config());
    }

    function test_preflightRejectsOwnerWithoutRegistrarAdminRoles() external {
        ethRegistry.revokeRootRoles(REGISTRAR_ADMIN_ROLES, EXPECTED_OWNER);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployDOSDomainPolicyTestnet.MissingRegistrarAdmin.selector,
                EXPECTED_OWNER
            )
        );
        deployer.preflight(EXPECTED_OWNER, _config());
    }

    function test_preflightRejectsLegacyRegistrarWithoutActiveRoles() external {
        ethRegistry.revokeRootRoles(REGISTRAR_ROLES, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployDOSDomainPolicyTestnet.LegacyRegistrarAlreadyRetired.selector,
                address(this)
            )
        );
        deployer.preflight(EXPECTED_OWNER, _config());
    }

    function _config()
        internal
        returns (DeployDOSDomainPolicyTestnet.DeploymentConfig memory config)
    {
        config = DeployDOSDomainPolicyTestnet.DeploymentConfig({registry: ethRegistry, priceOracle: rentPriceOracle, legacyRegistrar: address(
            this
        ), voucherSigner: makeAddr("voucherSigner"), minimumScore: 20, defaultResolver: address(0)});
    }
}
