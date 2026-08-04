// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {DOSRegistrar} from "~src/registrar/DOSRegistrar.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {L2ReverseRegistrar} from "~src/reverse-registrar/L2ReverseRegistrar.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {MockERC20} from "~test/mocks/MockERC20.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";
import {StandardRentPriceOracleFixture} from "~test/fixtures/StandardRentPriceOracleFixture.sol";
import {StandardRegistrar} from "~test/StandardRegistrar.sol";

import {DeployDOS} from "../../script/foundry/DeployDOS.s.sol";

/// @notice Integration coverage for the DOS Chain ENSv2 deployment profile.
contract DOSNameServiceTest is V2Fixture, StandardRentPriceOracleFixture {
    uint256 internal constant DOS_CHAIN_ID = 3939;
    uint256 internal constant DOS_COIN_TYPE = (1 << 31) | DOS_CHAIN_ID;
    string internal constant DOS_REVERSE_LABEL = "80000f63";

    PermissionedRegistry internal dosRegistry;
    DOSRegistrar internal dosRegistrar;
    L2ReverseRegistrar internal reverseRegistrar;

    address internal registrant = makeAddr("registrant");
    bytes32 internal secret = keccak256("dos-secret");

    function setUp() external {
        deployV2Fixture();
        deployStandardRentPriceOracleFixture();

        dosRegistry = new PermissionedRegistry(labelStore, address(this), _ethRegistryRootRoles());
        rootRegistry.register(
            "dos",
            address(this),
            dosRegistry,
            address(0),
            _ethTokenRoles(),
            type(uint64).max
        );
        dosRegistry.setParent(rootRegistry, "dos");

        dosRegistrar = new DOSRegistrar(
            address(this),
            dosRegistry,
            beneficiary,
            rentPriceOracle,
            StandardRegistrar.GRACE_PERIOD_V2,
            StandardRegistrar.MIN_COMMITMENT_AGE,
            StandardRegistrar.MAX_COMMITMENT_AGE,
            StandardRegistrar.MIN_REGISTER_DURATION
        );
        dosRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(dosRegistrar)
        );

        setupPaymentTokens(registrant, address(dosRegistrar));
        reverseRegistrar = new L2ReverseRegistrar(DOS_CHAIN_ID, DOS_REVERSE_LABEL);

        uint64 initialTimestamp = dosRegistrar.GRACE_PERIOD() + 1;
        if (block.timestamp < initialTimestamp) {
            vm.warp(initialTimestamp);
        }
    }

    function test_registersDosAsCanonicalTld() external view {
        assertEq(address(dosRegistrar.ETH_REGISTRY()), address(dosRegistry));
        assertEq(
            uint8(rootRegistry.getStatus(LibLabel.id("dos"))),
            uint8(IPermissionedRegistry.Status.REGISTERED)
        );
        (IRegistry parent, string memory label) = dosRegistry.getParent();
        assertEq(address(parent), address(rootRegistry));
        assertEq(label, "dos");
    }

    function test_registersAndRenewsDosName() external {
        string memory label = "alice";
        uint64 duration = StandardRegistrar.MIN_REGISTER_DURATION;
        MockERC20 paymentToken = tokenUSDC;
        uint256 tokenId = _register(label, duration, paymentToken);

        IPermissionedRegistry.State memory state = dosRegistry.getState(LibLabel.id(label));
        assertEq(state.tokenId, tokenId);
        assertEq(state.latestOwner, registrant);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.REGISTERED));
        assertEq(labelStore.getLabel(tokenId), label);

        uint64 expiry = state.expiry;
        vm.prank(registrant);
        dosRegistrar.renew(label, duration, IERC20(paymentToken), bytes32(0));
        assertEq(dosRegistry.getExpiry(tokenId), expiry + duration);
    }

    function test_setsPrimaryDosNameForDosChain() external {
        assertEq(reverseRegistrar.CHAIN_ID(), DOS_CHAIN_ID);
        assertEq(DOS_COIN_TYPE, 0x80000f63);

        vm.prank(registrant);
        reverseRegistrar.setName("alice.dos");

        assertEq(reverseRegistrar.nameForAddr(registrant), "alice.dos");
    }

    function test_deploymentProfileWiresDosContracts() external {
        DeployDOS deployer = new DeployDOS();
        DeployDOS.Deployment memory deployment =
            deployer.deploy(address(deployer), beneficiary, IERC20(tokenIdentity), DOS_CHAIN_ID);

        assertEq(address(deployment.dosRegistrar.ETH_REGISTRY()), address(deployment.dosRegistry));
        assertEq(deployment.reverseRegistrar.CHAIN_ID(), DOS_CHAIN_ID);
        assertEq(
            uint8(deployment.rootRegistry.getStatus(LibLabel.id("dos"))),
            uint8(IPermissionedRegistry.Status.REGISTERED)
        );
        (uint128 numer, uint128 denom) =
            deployment.priceOracle.getPaymentTokenRatio(IERC20(tokenIdentity));
        assertEq(numer, 1);
        assertEq(denom, 1);
        assertTrue(address(deployment.verifiableFactory) != address(0));
    }

    function test_deploymentRejectsPaymentTokenBelowPriceScale() external {
        DeployDOS deployer = new DeployDOS();
        MockERC20 lowDecimalToken = new MockERC20("Low decimals", 6);

        vm.expectRevert(
            abi.encodeWithSelector(DeployDOS.PaymentTokenDecimalsTooLow.selector, uint8(6))
        );
        deployer.deploy(address(deployer), beneficiary, IERC20(lowDecimalToken), DOS_CHAIN_ID);
    }

    function test_deploymentRejectsPaymentTokenAboveRatioCapacity() external {
        DeployDOS deployer = new DeployDOS();
        MockERC20 highDecimalToken = new MockERC20("High decimals", 51);

        vm.expectRevert(
            abi.encodeWithSelector(DeployDOS.PaymentTokenDecimalsTooHigh.selector, uint8(51))
        );
        deployer.deploy(address(deployer), beneficiary, IERC20(highDecimalToken), DOS_CHAIN_ID);
    }

    function test_deploymentConvertsEighteenDecimalPaymentToken() external {
        DeployDOS deployer = new DeployDOS();
        DeployDOS.Deployment memory deployment =
            deployer.deploy(address(deployer), beneficiary, IERC20(tokenDAI), DOS_CHAIN_ID);

        (uint128 numer, uint128 denom) =
            deployment.priceOracle.getPaymentTokenRatio(IERC20(tokenDAI));
        assertEq(numer, 1e6);
        assertEq(denom, 1);
    }

    function test_deploymentSupportsForwardAndReverseResolution() external {
        DeployDOS deployer = new DeployDOS();
        DeployDOS.Deployment memory deployment =
            deployer.deploy(address(deployer), beneficiary, IERC20(tokenIdentity), DOS_CHAIN_ID);

        bytes[] memory setters = new bytes[](0);
        vm.prank(registrant);
        PermissionedResolver resolver =
            PermissionedResolver(
                deployment.verifiableFactory.deployProxy(
                    address(deployment.permissionedResolverImplementation),
                    1,
                    abi.encodeCall(
                        PermissionedResolver.initialize,
                        (registrant, EACBaseRolesLib.ALL_ROLES, setters)
                    )
                )
            );

        tokenIdentity.mint(registrant, 1_000_000e12);
        vm.prank(registrant);
        tokenIdentity.approve(address(deployment.dosRegistrar), type(uint256).max);

        string memory label = "resolved";
        uint64 duration = StandardRegistrar.MIN_REGISTER_DURATION;
        bytes32 commitment =
            deployment.dosRegistrar.makeCommitment(
                label,
                registrant,
                secret,
                IRegistry(address(0)),
                address(resolver),
                duration,
                bytes32(0)
            );
        vm.prank(registrant);
        deployment.dosRegistrar.commit(commitment);
        vm.warp(block.timestamp + deployment.dosRegistrar.MIN_COMMITMENT_AGE());
        vm.prank(registrant);
        deployment.dosRegistrar.register(
            label,
            registrant,
            secret,
            IRegistry(address(0)),
            address(resolver),
            duration,
            IERC20(tokenIdentity),
            bytes32(0)
        );

        bytes memory dnsName = NameCoder.encode("resolved.dos");
        bytes32 node = NameCoder.namehash(dnsName, 0);
        vm.prank(registrant);
        resolver.setAddr(node, DOS_COIN_TYPE, abi.encodePacked(registrant));
        vm.prank(registrant);
        deployment.reverseRegistrar.setName("resolved.dos");

        (bytes memory forwardResult, address forwardResolver) =
            deployment.universalResolver.resolve(
                dnsName,
                abi.encodeCall(IAddressResolver.addr, (node, DOS_COIN_TYPE))
            );
        assertEq(abi.decode(forwardResult, (bytes)), abi.encodePacked(registrant));
        assertEq(forwardResolver, address(resolver));

        (string memory primary, address resolvedBy, address reverseResolvedBy) =
            deployment.universalResolver.reverse(abi.encodePacked(registrant), DOS_COIN_TYPE);
        assertEq(primary, "resolved.dos");
        assertEq(resolvedBy, address(resolver));
        assertEq(reverseResolvedBy, address(deployment.reverseRegistrar));
    }

    function _register(string memory label, uint64 duration, MockERC20 paymentToken)
        internal
        returns (uint256 tokenId)
    {
        bytes32 commitment =
            dosRegistrar.makeCommitment(
                label,
                registrant,
                secret,
                IRegistry(address(0)),
                address(0),
                duration,
                bytes32(0)
            );

        vm.prank(registrant);
        dosRegistrar.commit(commitment);
        vm.warp(block.timestamp + dosRegistrar.MIN_COMMITMENT_AGE());

        vm.prank(registrant);
        tokenId = dosRegistrar.register(
            label,
            registrant,
            secret,
            IRegistry(address(0)),
            address(0),
            duration,
            IERC20(paymentToken),
            bytes32(0)
        );
    }
}
