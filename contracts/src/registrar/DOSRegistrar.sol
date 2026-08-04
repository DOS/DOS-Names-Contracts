// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";

import {ETHRegistrar} from "./ETHRegistrar.sol";
import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";

/// @title DOS Registrar
/// @notice DOS Chain deployment profile for registering and renewing `.dos` names.
/// @dev The implementation deliberately inherits the audited ENSv2 registrar without
///      overriding registration behavior so future upstream fixes remain easy to adopt.
contract DOSRegistrar is ETHRegistrar {
    /// @param owner_ Contract owner.
    /// @param dosRegistry ENSv2 `.dos` permissioned registry.
    /// @param beneficiary Address that receives registration and renewal payments.
    /// @param oracle Initial oracle for registration and renewal prices.
    /// @param gracePeriod Post-expiry period where names remain renewable.
    /// @param minCommitmentAge Minimum commitment age before registration.
    /// @param maxCommitmentAge Maximum commitment age before expiration.
    /// @param minRegisterDuration Minimum registration duration.
    constructor(
        address owner_,
        IPermissionedRegistry dosRegistry,
        address beneficiary,
        IRentPriceOracle oracle,
        uint64 gracePeriod,
        uint64 minCommitmentAge,
        uint64 maxCommitmentAge,
        uint64 minRegisterDuration
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
    {}
}
