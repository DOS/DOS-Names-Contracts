// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";

import {AbstractETHRegistrar} from "./AbstractETHRegistrar.sol";
import {ETHRegistrar} from "./ETHRegistrar.sol";
import {IETHRenewer} from "./interfaces/IETHRenewer.sol";
import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";

/// @notice DOS Chain registrar that can only be operated through one policy controller.
/// @dev The registrar preserves the ENSv2 pricing, commitment, expiry and event behavior.
///      The controller only gates who may invoke registration and renewal.
contract DOSPolicyRegistrar is ETHRegistrar {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Policy contract allowed to invoke `register` and `renew`.
    address public immutable REGISTRATION_CONTROLLER;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0xed6f956a`
    error InvalidRegistrationController();
    /// @dev Error selector: `0x653353a4`
    error UnauthorizedRegistrationController(address caller, address registrationController);

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    modifier onlyRegistrationController() {
        if (msg.sender != REGISTRATION_CONTROLLER) {
            revert UnauthorizedRegistrationController(msg.sender, REGISTRATION_CONTROLLER);
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param owner_ The registrar administrator.
    /// @param dosRegistry The `.dos` registry.
    /// @param beneficiary The recipient of registration and renewal payments.
    /// @param oracle The ENSv2 rent price oracle.
    /// @param gracePeriod The post-expiry renewal period in seconds.
    /// @param minCommitmentAge The minimum commitment age in seconds.
    /// @param maxCommitmentAge The maximum commitment age in seconds.
    /// @param minRegisterDuration The minimum registration duration in seconds.
    /// @param registrationController The only policy allowed to invoke registration and renewal.
    constructor(
        address owner_,
        IPermissionedRegistry dosRegistry,
        address beneficiary,
        IRentPriceOracle oracle,
        uint64 gracePeriod,
        uint64 minCommitmentAge,
        uint64 maxCommitmentAge,
        uint64 minRegisterDuration,
        address registrationController
    )
        ETHRegistrar(
            owner_,
            dosRegistry,
            beneficiary,
            oracle,
            gracePeriod,
            minCommitmentAge,
            maxCommitmentAge,
            minRegisterDuration
        )
    {
        if (registrationController == address(0)) {
            revert InvalidRegistrationController();
        }
        REGISTRATION_CONTROLLER = registrationController;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ETHRegistrar
    function register(
        string calldata label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    )
        external
        override
        onlyRegistrationController
        returns (uint256 tokenId)
    {
        return
            _register(label, owner, secret, subregistry, resolver, duration, paymentToken, referrer);
    }

    /// @inheritdoc IETHRenewer
    function renew(string calldata label, uint64 duration, IERC20 paymentToken, bytes32 referrer)
        external
        override(AbstractETHRegistrar, IETHRenewer)
        onlyRegistrationController
    {
        _renew(label, duration, paymentToken, referrer);
    }
}
