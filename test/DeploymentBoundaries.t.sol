// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract DeploymentBoundariesTest is LaunchFixture {
    function setUp() public {
        _deploy(false, false);
    }

    function test_ConstructorRejectsNonContractsAndIdenticalCurrencies() public {
        address eoa = makeAddr("no code");
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(IPoolManager(eoa), address(token));
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, eoa);
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, IMD);
    }

    function test_Create2RejectsAddressWithIncorrectPermissionBits() public {
        bytes32 hash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)));
        uint256 salt;
        address predicted;
        do {
            ++salt;
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), bytes32(salt), hash))))
            );
        } while ((uint160(predicted) & 0x3fff) == 0x20c4);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SIMDTESTHook{salt: bytes32(salt)}(manager, address(token));
        assertEq(predicted.code.length, 0);
    }

    function test_WrongPoolBeforeFirstInitializationCannotPoisonLaunch() public {
        // Exercise key validation before initialized is true; otherwise that check short-circuits it.
        for (uint256 i; i < 5; ++i) {
            PoolKey memory other = hook.poolKey();
            if (i == 0) other.fee = 3000;
            if (i == 1) other.fee = 0x800000;
            if (i == 2) other.tickSpacing = 120;
            if (i == 3) other.currency0 = Currency.wrap(address(1));
            if (i == 4) other.currency1 = Currency.wrap(address(type(uint160).max));
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeInitialize.selector,
                    abi.encodeWithSelector(SIMDTESTHook.WrongPool.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            manager.initialize(other, Q96);
            assertFalse(hook.initialized());
            assertEq(hook.referencePrice(), 0);
            assertEq(hook.lastBatch(), 0);
        }
        manager.initialize(key, Q96);
        assertTrue(hook.initialized());
        assertEq(hook.referencePrice(), Q96);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.WrongPool.selector);
        hook.beforeInitialize(address(this), key, Q96);
    }

    function test_UninitializedBatchFailsButSweepAndLaterInitializationWork() public {
        vm.warp(vm.getBlockTimestamp() + 7200);
        vm.expectRevert(SIMDTESTHook.NotInitialized.selector);
        hook.executeBatch();
        token.transfer(address(hook), 100);
        assertEq(hook.sweep(), 100);
        assertEq(token.balanceOf(DEAD), 100);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.referencePrice(), 0);
        manager.initialize(key, Q96);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.executeBatch();
        vm.warp(vm.getBlockTimestamp() + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent + burned, 0);
        _assertSettled();
    }

    function test_UnrepresentableFeeBoundaryForBothSpecifiedSigns() public {
        uint256 maximum = uint256(type(int256).max);
        // For x = 100*q+r, x+floor(x/100) = 101*q+r (0 <= r < 100).
        uint256 remainder = maximum % 101;
        uint256 boundary = maximum / 101 * 100 + (remainder < 100 ? remainder : 99);
        assertLe(boundary + boundary / 100, maximum);
        assertGt(boundary + 1 + (boundary + 1) / 100, maximum);
        for (uint256 sign; sign < 2; ++sign) {
            SwapParams memory params =
                SwapParams(true, sign == 0 ? int256(boundary) : -int256(boundary), Q96 / 2);
            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 overrideFee) =
                hook.beforeSwap(address(actor), key, params, "");
            assertEq(selector, IHooks.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0, "must not reserve requested-side fees");
            assertEq(overrideFee, 0, "must not override static LP fee");
            params.amountSpecified = sign == 0 ? int256(boundary + 1) : -int256(boundary + 1);
            vm.prank(address(manager));
            vm.expectRevert(SIMDTESTHook.UnrepresentableFee.selector);
            hook.beforeSwap(address(actor), key, params, "");
        }
    }
}
