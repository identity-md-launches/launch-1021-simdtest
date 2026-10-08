// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Read-only salt search. No wallet, environment, broadcast or filesystem access.
/// @dev factory MUST be the contract that actually executes CREATE2, including its salt convention.
contract MineHook {
    function run(address factory, IPoolManager manager, address token, uint256 start)
        public
        pure
        returns (address predicted, bytes32 salt)
    {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)));
        uint160 flags = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
            | HookFlags.AFTER_SWAP_RETURN_DELTA;
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, salt, initHash)))));
            if (HookFlags.matches(predicted, flags)) return (predicted, salt);
        }
        revert("Continue with start + 200000");
    }
}
