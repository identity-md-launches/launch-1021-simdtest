// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";

/// @dev Real PoolManager settlement, deliberately settling input AFTER swap callbacks.
contract PoolActor is IUnlockCallback {
    IPoolManager public immutable manager;
    bool public nestedCallRefused;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return
            abi.decode(
                manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(params))), (BalanceDelta)
            );
    }

    function liquidity(PoolKey memory key, int24 lower, int24 upper, int256 amount)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(
                abi.encode(
                    uint8(1), msg.sender, key, abi.encode(ModifyLiquidityParams(lower, upper, amount, 0))
                )
            ),
            (BalanceDelta)
        );
    }

    function tryNestedBatch(PoolKey memory key) external {
        manager.unlock(abi.encode(uint8(2), msg.sender, key, bytes("")));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address payer, PoolKey memory key, bytes memory payload) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(payload, (SwapParams)), "");
        } else if (action == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
        } else {
            try SIMDTESTHook(address(key.hooks)).executeBatch() {
                revert("batch entered another unlock");
            } catch (bytes memory reason) {
                require(bytes4(reason) == SIMDTESTHook.SeparateUnlockRequired.selector, "unexpected error");
                nestedCallRefused = true;
            }
        }
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta < 0) {
            manager.sync(currency);
            require(
                IERC20(Currency.unwrap(currency))
                    .transferFrom(payer, address(manager), uint256(-int256(delta)))
            );
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        }
    }
}
