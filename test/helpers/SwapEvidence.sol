// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev PoolManager emits this receipt before applying hook return deltas.
/// Neither FeeAccrued nor pending() is used to compute the expected fee.
library SwapEvidence {
    bytes32 internal constant SIGNATURE =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    struct Receipt {
        BalanceDelta delta;
        uint160 price;
        int24 tick;
        uint24 lpFee;
        address sender;
    }

    function read(Vm.Log[] memory logs, address manager, PoolId pool)
        internal
        pure
        returns (Receipt memory receipt)
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != manager || logs[i].topics.length != 3) continue;
            if (logs[i].topics[0] != SIGNATURE || logs[i].topics[1] != PoolId.unwrap(pool)) continue;
            (int128 a0, int128 a1, uint160 price,, int24 tick, uint24 fee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            receipt = Receipt(
                toBalanceDelta(a0, a1), price, tick, fee, address(uint160(uint256(logs[i].topics[2])))
            );
            ++count;
        }
        require(count == 1, "expected exactly one swap in the launch pool");
    }
}
