// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployDOS} from "./DeployDOS.s.sol";
import {DeployDOSTestnet} from "./DeployDOSTestnet.s.sol";

/// @title Deploy DOS Name Service on mainnet
/// @notice Deploys the complete `.dos` ENSv2 stack against the canonical WDOS contract.
contract DeployDOSMainnet is DeployDOSTestnet {
    uint256 internal constant MAINNET_CHAIN_ID = 7979;
    address internal constant MAINNET_DEPLOYER = 0x99999e454138f6be73E2bE82c890bc5765749999;
    address internal constant MAINNET_OWNER = 0x310Bc061214ee89aF5CfB28a6ebF96c5436fa3CD;
    uint8 internal constant MAINNET_WDOS_DECIMALS = 18;

    error MainnetUnexpectedChain(uint256 actual, uint256 expected);
    error MainnetUnexpectedDeployer(address actual, address expected);
    error MainnetUnexpectedOwner(address actual, address expected);
    error MainnetUnexpectedBeneficiary(address actual, address expected);
    error MainnetInsufficientDeploymentBalance(uint256 actual, uint256 required);
    error MissingPaymentTokenCode(address paymentToken);
    error UnexpectedPaymentTokenDecimals(uint8 actual, uint8 expected);

    /// @notice Contracts produced by the DOS mainnet deployment profile.
    struct MainnetDeployment {
        IERC20 paymentToken;
        DeployDOS.Deployment names;
    }

    /// @notice Broadcasts the canonical Mainnet deployment using environment configuration.
    /// @dev Required env: `PRIVATE_KEY`, `OWNER`. Optional env: `BENEFICIARY`.
    function run() external override returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address beneficiary = vm.envOr("BENEFICIARY", owner);
        address broadcaster = vm.addr(privateKey);

        preflightMainnet(broadcaster, owner, beneficiary, DEFAULT_WDOS);
        vm.startBroadcast(privateKey);
        MainnetDeployment memory mainnetDeployment =
            deployMainnet(broadcaster, owner, beneficiary, IERC20(DEFAULT_WDOS), block.chainid);
        vm.stopBroadcast();

        deployment = mainnetDeployment.names;
    }

    /// @notice Fails before broadcasting if the Mainnet deployment configuration is not canonical.
    function preflightMainnet(address broadcaster, address owner, address beneficiary, address paymentToken)
        public
        view
    {
        if (block.chainid != MAINNET_CHAIN_ID) {
            revert MainnetUnexpectedChain(block.chainid, MAINNET_CHAIN_ID);
        }
        if (broadcaster != MAINNET_DEPLOYER) {
            revert MainnetUnexpectedDeployer(broadcaster, MAINNET_DEPLOYER);
        }
        if (owner != MAINNET_OWNER) {
            revert MainnetUnexpectedOwner(owner, MAINNET_OWNER);
        }
        if (beneficiary != MAINNET_OWNER) {
            revert MainnetUnexpectedBeneficiary(beneficiary, MAINNET_OWNER);
        }
        if (broadcaster.balance < MIN_DEPLOYMENT_BALANCE) {
            revert MainnetInsufficientDeploymentBalance(broadcaster.balance, MIN_DEPLOYMENT_BALANCE);
        }
        if (paymentToken.code.length == 0) {
            revert MissingPaymentTokenCode(paymentToken);
        }
        uint8 decimals = IERC20Metadata(paymentToken).decimals();
        if (decimals != MAINNET_WDOS_DECIMALS) {
            revert UnexpectedPaymentTokenDecimals(decimals, MAINNET_WDOS_DECIMALS);
        }
    }

    /// @notice Deploys ENSv2 against an existing payment token and hands all control to the owner.
    function deployMainnet(
        address initialOwner,
        address owner,
        address beneficiary,
        IERC20 paymentToken,
        uint256 chainId
    ) public returns (MainnetDeployment memory deployment) {
        deployment.paymentToken = paymentToken;
        deployment.names = deploy(initialOwner, beneficiary, paymentToken, chainId);
        _registerBensSmokeName(deployment.names, initialOwner, owner, chainId);
        _handoff(deployment.names, initialOwner, owner);
    }
}
