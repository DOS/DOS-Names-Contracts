// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {WETH} from "solady/tokens/WETH.sol";

/// @title Wrapped DOS
/// @notice Standard wrapped-native token used by DOS Chain testnet integrations.
contract WrappedDOS is WETH {
    /// @inheritdoc WETH
    function name() public pure override returns (string memory) {
        return "Wrapped DOS";
    }

    /// @inheritdoc WETH
    function symbol() public pure override returns (string memory) {
        return "WDOS";
    }
}
