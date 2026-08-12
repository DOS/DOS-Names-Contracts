// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployDOS} from "../../../script/foundry/DeployDOS.s.sol";
import {DeployDOSTestnet} from "../../../script/foundry/DeployDOSTestnet.s.sol";

import {DOSRegistrar} from "~src/registrar/DOSRegistrar.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {WrappedDOS} from "~src/testnet/WrappedDOS.sol";

contract WrappedDOSTest is Test {
    WrappedDOS internal wdos;
    address internal holder = makeAddr("holder");
    address internal recipient = makeAddr("recipient");
    DOSRegistrar internal testnetRegistrar;
    WrappedDOS internal testnetPaymentToken;
    address internal paymentRegistrant;
    address internal paymentBeneficiary;

    function setUp() external {
        wdos = new WrappedDOS();
        vm.deal(holder, 10 ether);
    }

    function test_metadataMatchesDOSNativeToken() external view {
        assertEq(wdos.name(), "Wrapped DOS");
        assertEq(wdos.symbol(), "WDOS");
        assertEq(wdos.decimals(), 18);
    }

    function test_depositMintsOneToOneWrappedDOS() external {
        vm.prank(holder);
        wdos.deposit{value: 3 ether}();

        assertEq(wdos.balanceOf(holder), 3 ether);
        assertEq(address(wdos).balance, 3 ether);
        assertEq(wdos.totalSupply(), 3 ether);
    }

    function test_transferAndWithdrawReturnNativeDOS() external {
        vm.prank(holder);
        wdos.deposit{value: 3 ether}();

        vm.prank(holder);
        wdos.transfer(recipient, 1 ether);

        uint256 nativeBalanceBefore = recipient.balance;
        vm.prank(recipient);
        wdos.withdraw(1 ether);

        assertEq(wdos.balanceOf(holder), 2 ether);
        assertEq(wdos.balanceOf(recipient), 0);
        assertEq(recipient.balance, nativeBalanceBefore + 1 ether);
        assertEq(address(wdos).balance, 2 ether);
        assertEq(wdos.totalSupply(), 2 ether);
    }

    function test_receiveMintsWrappedDOS() external {
        vm.prank(holder);
        (bool success, ) = address(wdos).call{value: 2 ether}("");

        assertTrue(success);
        assertEq(wdos.balanceOf(holder), 2 ether);
    }

    function test_testnetDeploymentWiresWrappedDOSAndExternalOwner() external {
        DeployDOSTestnet deployer = new DeployDOSTestnet();
        address protocolOwner = makeAddr("protocolOwner");
        address beneficiary = makeAddr("beneficiary");

        DeployDOSTestnet.TestnetDeployment memory deployment =
            deployer.deployTestnet(address(deployer), protocolOwner, beneficiary, 3939);

        assertEq(deployment.wdos.name(), "Wrapped DOS");
        assertEq(deployment.wdos.symbol(), "WDOS");
        assertEq(deployment.names.dosRegistrar.owner(), protocolOwner);
        assertEq(deployment.names.dosRegistrar.BENEFICIARY(), beneficiary);
        assertEq(deployment.names.rootRegistry.roles(0, address(deployer)), 0);
        assertEq(deployment.names.dosRegistry.roles(0, address(deployer)), 0);
        assertEq(deployment.names.reverseRegistry.roles(0, address(deployer)), 0);
        assertEq(deployment.names.priceOracle.roles(0, address(deployer)), 0);
        assertEq(deployment.names.permissionedResolverImplementation.roles(0, address(deployer)), 0);
        assertEq(deployment.names.userRegistryImplementation.roles(0, address(deployer)), 0);
        assertTrue(deployment.names.rootRegistry.roles(0, protocolOwner) != 0);
        assertTrue(deployment.names.dosRegistry.roles(0, protocolOwner) != 0);
        assertTrue(deployment.names.reverseRegistry.roles(0, protocolOwner) != 0);
        assertTrue(deployment.names.priceOracle.roles(0, protocolOwner) != 0);
        assertTrue(deployment.names.permissionedResolverImplementation.roles(0, protocolOwner) != 0);
        assertTrue(deployment.names.userRegistryImplementation.roles(0, protocolOwner) != 0);

        uint256 dosTokenId = deployment.names.rootRegistry.getTokenId(LibLabel.id("dos"));
        uint256 reverseTokenId = deployment.names.rootRegistry.getTokenId(LibLabel.id("reverse"));
        uint256 smokeTokenId = deployment.names.dosRegistry.getTokenId(LibLabel.id("bens-smoke"));
        assertEq(deployment.names.rootRegistry.ownerOf(dosTokenId), protocolOwner);
        assertEq(deployment.names.rootRegistry.ownerOf(reverseTokenId), protocolOwner);
        assertEq(deployment.names.rootRegistry.roles(dosTokenId, address(deployer)), 0);
        assertEq(deployment.names.rootRegistry.roles(reverseTokenId, address(deployer)), 0);
        assertTrue(deployment.names.rootRegistry.roles(dosTokenId, protocolOwner) != 0);
        assertTrue(deployment.names.rootRegistry.roles(reverseTokenId, protocolOwner) != 0);
        assertEq(deployment.names.dosRegistry.ownerOf(smokeTokenId), protocolOwner);
        assertLe(
            deployment.names.dosRegistry.getExpiry(smokeTokenId),
            253402300799,
            "smoke expiry must remain BENS/PostgreSQL timestamp-safe"
        );

        vm.expectRevert();
        vm.prank(address(deployer));
        deployment.names.rootRegistry.setResolver(dosTokenId, address(1));

        vm.expectRevert();
        vm.prank(address(deployer));
        deployment.names.rootRegistry.setSubregistry(
            reverseTokenId,
            IRegistry(address(deployment.names.dosRegistry))
        );

        (uint128 numer, uint128 denom) =
            deployment.names.priceOracle.getPaymentTokenRatio(IERC20(address(deployment.wdos)));
        assertEq(numer, 1e6);
        assertEq(denom, 1);
    }

    function test_runUsesCanonicalTestnetFlow() external {
        DeployDOSTestnet deployer = new DeployDOSTestnet();
        uint256 privateKey = 0xA11CE;
        address protocolOwner = makeAddr("runProtocolOwner");
        address beneficiary = makeAddr("runBeneficiary");

        vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
        vm.setEnv("OWNER", vm.toString(protocolOwner));
        vm.setEnv("BENEFICIARY", vm.toString(beneficiary));

        DeployDOS.Deployment memory deployment = deployer.run();

        assertEq(deployment.dosRegistrar.owner(), protocolOwner);
        assertEq(deployment.dosRegistrar.BENEFICIARY(), beneficiary);
    }

    function test_testnetRegistrationUsesWrappedDOSAndPaysBeneficiary() external {
        DeployDOSTestnet deployer = new DeployDOSTestnet();
        address protocolOwner = makeAddr("paymentProtocolOwner");
        paymentBeneficiary = makeAddr("paymentBeneficiary");
        paymentRegistrant = makeAddr("registrant");

        DeployDOSTestnet.TestnetDeployment memory deployment =
            deployer.deployTestnet(address(deployer), protocolOwner, paymentBeneficiary, 3939);
        testnetRegistrar = deployment.names.dosRegistrar;
        testnetPaymentToken = deployment.wdos;

        vm.deal(paymentRegistrant, 1_000 ether);
        vm.startPrank(paymentRegistrant);
        testnetPaymentToken.deposit{value: 1_000 ether}();
        testnetPaymentToken.approve(address(testnetRegistrar), type(uint256).max);
        vm.stopPrank();

        vm.warp(testnetRegistrar.GRACE_PERIOD() + 1);

        _registerAndRenew("a", 100_00002528e10);
        _registerAndRenew("ab", 50_00001264e10);
        _registerAndRenew("abc", 10_000002528e9);

        assertEq(deployment.wdos.balanceOf(address(deployer)), 0);
        assertEq(deployment.wdos.balanceOf(protocolOwner), 0);
    }

    function _registerAndRenew(string memory label, uint256 expectedPrice) internal {
        uint64 duration = 365 days;
        bytes32 secret = keccak256(bytes(label));
        bytes32 commitment =
            testnetRegistrar.makeCommitment(
                label,
                paymentRegistrant,
                secret,
                IRegistry(address(0)),
                address(0),
                duration,
                bytes32(0)
            );

        vm.prank(paymentRegistrant);
        testnetRegistrar.commit(commitment);
        vm.warp(block.timestamp + testnetRegistrar.MIN_COMMITMENT_AGE());

        (uint256 base, uint256 premium) =
            testnetRegistrar.getRegisterPrice(label, duration, IERC20(address(testnetPaymentToken)));
        assertEq(base, expectedPrice);
        assertEq(premium, 0);

        uint256 beneficiaryBefore = testnetPaymentToken.balanceOf(paymentBeneficiary);
        vm.prank(paymentRegistrant);
        testnetRegistrar.register(
            label,
            paymentRegistrant,
            secret,
            IRegistry(address(0)),
            address(0),
            duration,
            IERC20(address(testnetPaymentToken)),
            bytes32(0)
        );
        assertEq(
            testnetPaymentToken.balanceOf(paymentBeneficiary),
            beneficiaryBefore + expectedPrice
        );

        uint256 renewalPrice =
            testnetRegistrar.getRenewPrice(label, duration, IERC20(address(testnetPaymentToken)));
        assertEq(renewalPrice, expectedPrice);

        vm.prank(paymentRegistrant);
        testnetRegistrar.renew(label, duration, IERC20(address(testnetPaymentToken)), bytes32(0));
        assertEq(
            testnetPaymentToken.balanceOf(paymentBeneficiary),
            beneficiaryBefore + 2 * expectedPrice
        );
    }
}
