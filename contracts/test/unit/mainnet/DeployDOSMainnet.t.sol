// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {DeployDOSMainnet} from "../../../script/foundry/DeployDOSMainnet.s.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {WrappedDOS} from "~src/testnet/WrappedDOS.sol";
import {MockERC20} from "~test/mocks/MockERC20.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

contract DeployDOSMainnetTest is Test {
    uint256 internal constant MAINNET_CHAIN_ID = 7979;
    address internal constant MAINNET_DEPLOYER = 0x99999e454138f6be73E2bE82c890bc5765749999;
    address internal constant PROTOCOL_OWNER = 0x310Bc061214ee89aF5CfB28a6ebF96c5436fa3CD;
    address internal constant CANONICAL_WDOS = 0x1111111111111111111111111111111111111111;

    function test_mainnetDeploymentUsesExistingWDOSAndHandsOffControl() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        WrappedDOS paymentToken = new WrappedDOS();

        DeployDOSMainnet.MainnetDeployment memory deployment = deployer.deployMainnet(
            address(deployer), PROTOCOL_OWNER, PROTOCOL_OWNER, IERC20(address(paymentToken)), 7979
        );

        assertEq(address(deployment.paymentToken), address(paymentToken));
        assertEq(deployment.names.dosRegistrar.owner(), PROTOCOL_OWNER);
        assertEq(deployment.names.dosRegistrar.BENEFICIARY(), PROTOCOL_OWNER);
        assertEq(deployment.names.rootRegistry.roles(0, address(deployer)), 0);
        assertEq(deployment.names.dosRegistry.roles(0, address(deployer)), 0);
        assertEq(deployment.names.reverseRegistry.roles(0, address(deployer)), 0);
        assertEq(deployment.names.priceOracle.roles(0, address(deployer)), 0);
        assertEq(deployment.names.permissionedResolverImplementation.roles(0, address(deployer)), 0);
        assertEq(deployment.names.userRegistryImplementation.roles(0, address(deployer)), 0);

        uint256 dosTokenId = deployment.names.rootRegistry.getTokenId(LibLabel.id("dos"));
        uint256 reverseTokenId = deployment.names.rootRegistry.getTokenId(LibLabel.id("reverse"));
        uint256 smokeTokenId = deployment.names.dosRegistry.getTokenId(LibLabel.id("bens-smoke"));
        assertEq(deployment.names.rootRegistry.ownerOf(dosTokenId), PROTOCOL_OWNER);
        assertEq(deployment.names.rootRegistry.ownerOf(reverseTokenId), PROTOCOL_OWNER);
        assertEq(deployment.names.dosRegistry.ownerOf(smokeTokenId), PROTOCOL_OWNER);
        assertLe(deployment.names.dosRegistry.getExpiry(smokeTokenId), 253402300799);

        address resolverAddress = deployment.names.dosRegistry.getResolver("bens-smoke");
        bytes32 node = NameCoder.namehash(NameCoder.encode("bens-smoke.dos"), 0);
        assertEq(PermissionedResolver(resolverAddress).addr(node), address(deployer));
        assertEq(deployment.names.reverseRegistrar.nameForAddr(address(deployer)), "bens-smoke.dos");

        vm.expectRevert();
        vm.prank(address(deployer));
        deployment.names.rootRegistry.setSubregistry(reverseTokenId, IRegistry(address(deployment.names.dosRegistry)));
    }

    function test_preflightAcceptsCanonicalMainnetConfiguration() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        WrappedDOS paymentToken = new WrappedDOS();
        vm.chainId(MAINNET_CHAIN_ID);
        vm.deal(MAINNET_DEPLOYER, 1 ether);

        deployer.preflightMainnet(MAINNET_DEPLOYER, PROTOCOL_OWNER, PROTOCOL_OWNER, address(paymentToken));
    }

    function test_preflightRejectsWrongChain() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        WrappedDOS paymentToken = new WrappedDOS();
        vm.chainId(3939);
        vm.deal(MAINNET_DEPLOYER, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DeployDOSMainnet.MainnetUnexpectedChain.selector, 3939, 7979));
        deployer.preflightMainnet(MAINNET_DEPLOYER, PROTOCOL_OWNER, PROTOCOL_OWNER, address(paymentToken));
    }

    function test_preflightRejectsWrongSigner() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        WrappedDOS paymentToken = new WrappedDOS();
        address wrongSigner = makeAddr("wrongSigner");
        vm.chainId(MAINNET_CHAIN_ID);
        vm.deal(wrongSigner, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(DeployDOSMainnet.MainnetUnexpectedDeployer.selector, wrongSigner, MAINNET_DEPLOYER)
        );
        deployer.preflightMainnet(wrongSigner, PROTOCOL_OWNER, PROTOCOL_OWNER, address(paymentToken));
    }

    function test_preflightRejectsWrongOwner() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        WrappedDOS paymentToken = new WrappedDOS();
        address wrongOwner = makeAddr("wrongOwner");
        vm.chainId(MAINNET_CHAIN_ID);
        vm.deal(MAINNET_DEPLOYER, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(DeployDOSMainnet.MainnetUnexpectedOwner.selector, wrongOwner, PROTOCOL_OWNER)
        );
        deployer.preflightMainnet(MAINNET_DEPLOYER, wrongOwner, PROTOCOL_OWNER, address(paymentToken));
    }

    function test_preflightRejectsWrongBeneficiary() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        WrappedDOS paymentToken = new WrappedDOS();
        address wrongBeneficiary = makeAddr("wrongBeneficiary");
        vm.chainId(MAINNET_CHAIN_ID);
        vm.deal(MAINNET_DEPLOYER, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployDOSMainnet.MainnetUnexpectedBeneficiary.selector, wrongBeneficiary, PROTOCOL_OWNER
            )
        );
        deployer.preflightMainnet(MAINNET_DEPLOYER, PROTOCOL_OWNER, wrongBeneficiary, address(paymentToken));
    }

    function test_preflightRejectsInsufficientBalance() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        WrappedDOS paymentToken = new WrappedDOS();
        vm.chainId(MAINNET_CHAIN_ID);
        vm.deal(MAINNET_DEPLOYER, 1 ether - 1);

        vm.expectRevert(
            abi.encodeWithSelector(DeployDOSMainnet.MainnetInsufficientDeploymentBalance.selector, 1 ether - 1, 1 ether)
        );
        deployer.preflightMainnet(MAINNET_DEPLOYER, PROTOCOL_OWNER, PROTOCOL_OWNER, address(paymentToken));
    }

    function test_preflightRejectsWrongWDOSDecimals() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        MockERC20 paymentToken = new MockERC20("Wrong decimals", 17);
        vm.chainId(MAINNET_CHAIN_ID);
        vm.deal(MAINNET_DEPLOYER, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DeployDOSMainnet.UnexpectedPaymentTokenDecimals.selector, 17, 18));
        deployer.preflightMainnet(MAINNET_DEPLOYER, PROTOCOL_OWNER, PROTOCOL_OWNER, address(paymentToken));
    }

    function test_preflightRejectsMissingWDOSCode() external {
        DeployDOSMainnet deployer = new DeployDOSMainnet();
        vm.chainId(MAINNET_CHAIN_ID);
        vm.deal(MAINNET_DEPLOYER, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DeployDOSMainnet.MissingPaymentTokenCode.selector, CANONICAL_WDOS));
        deployer.preflightMainnet(MAINNET_DEPLOYER, PROTOCOL_OWNER, PROTOCOL_OWNER, CANONICAL_WDOS);
    }
}
