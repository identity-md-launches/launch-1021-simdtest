// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract HookScenarios is LaunchFixture {
    using StateLibrary for IPoolManager;

    function test_ExactInputBuy() public {
        _checkFee(true, true, 1000 ether, 0, false);
    }

    function test_ExactInputSell() public {
        _checkFee(false, true, 1000 ether, 0, false);
    }

    function test_ExactOutputBuy() public {
        _checkFee(true, false, 1000 ether, 0, false);
    }

    function test_ExactOutputSell() public {
        _checkFee(false, false, 1000 ether, 0, false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FeeMatchesRealFill(bool buy, bool exactInput, uint256 amount) public {
        amount = bound(amount, 1, 10_000 ether);
        _checkFee(buy, exactInput, amount, 0, false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PartialFillOnlyTaxesFilledUnspecifiedCurrency(
        bool buy,
        bool exactInput,
        uint24 distance
    ) public {
        int24 ticks = int24(uint24(bound(distance, 1, 20)));
        bool direction = buy ? buyDirection : !buyDirection;
        uint160 limit = TickMath.getSqrtPriceAtTick(direction ? -ticks : ticks);
        _checkFee(buy, exactInput, 1_000_000 ether, limit, true);
    }

    function test_PermissionBitsAndInitialization() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap && p.afterSwapReturnDelta);
        assertFalse(p.beforeSwapReturnDelta || p.afterInitialize || p.beforeDonate || p.afterDonate);
        assertFalse(
            p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity
        );
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & 0x3fff, hook.FLAGS());
        assertTrue(hook.initialized());
        assertEq(hook.referencePrice(), Q96);
        assertEq(hook.lastBatch(), block.timestamp);
    }

    function test_AllCallbacksRejectUnauthorizedCallers() public {
        SwapParams memory p = SwapParams(true, -1 ether, Q96 / 2);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function test_RejectsOtherPoolsAndReinitialization() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, Q96);
        other.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(other, Q96);
        vm.expectRevert();
        manager.initialize(key, Q96);
        assertEq(hook.referencePrice(), Q96);
    }

    function test_UnrepresentableSpecifiedAmountRefused() public {
        SwapParams memory p = SwapParams(buyDirection, type(int256).max, buyDirection ? Q96 / 2 : Q96 * 2);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.UnrepresentableFee.selector);
        hook.beforeSwap(address(actor), key, p, "");
        vm.expectRevert();
        actor.swap(key, p);
        p.amountSpecified = type(int256).min;
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.UnrepresentableFee.selector);
        hook.beforeSwap(address(actor), key, p, "");
    }

    function test_AnyoneSweepsTokenFeesImmediatelyAndIdempotently() public {
        _swap(true, true, 1000 ether, 0);
        _swap(false, false, 1000 ether, 0);
        token.transfer(address(hook), 17);
        uint256 amount = hook.pendingBurn();
        assertGt(amount, 0);
        uint256 pairBefore = hook.pending();
        vm.prank(makeAddr("keeper"));
        assertEq(hook.sweep(), amount);
        assertEq(token.balanceOf(DEAD), amount);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.pending(), pairBefore);
        assertEq(hook.sweep(), 0);
        assertEq(token.totalSupply(), 1e27, "dead-address burn must not reduce ERC20 supply");
        _assertSettled();
    }

    function test_BatchUses25PercentBurnsOutputAndChargesNoHookFee() public {
        _swap(false, true, 10_000 ether, 0);
        _swap(true, true, 1000 ether, 0);
        uint256 burnPending = hook.pendingBurn();
        uint256 accrued = hook.pending();
        assertGt(accrued, 0);
        vm.warp(block.timestamp + 3600);
        vm.prank(makeAddr("batch keeper"));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, accrued / 4);
        assertGt(burned, 0);
        assertEq(hook.pending(), accrued - spent);
        assertEq(token.balanceOf(DEAD), burned);
        assertEq(hook.pendingBurn(), burnPending, "batch charged itself a hook fee");
        assertEq(hook.lastBatch(), block.timestamp);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.executeBatch();
        _assertSettled();
    }

    function test_BatchPriceLimitAcceptsPartialFillAndRemainderLater() public {
        IERC20(IMD).transfer(address(hook), 20_000_000 ether);
        vm.warp(block.timestamp + 3600);
        uint256 before = hook.pending();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertLt(spent, before / 4);
        assertGt(burned, 0, "static 1.25% LP fee must not cause min-output deadlock");
        assertEq(hook.pending(), before - spent);
        assertEq(token.balanceOf(DEAD), burned);
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        // Exact expected bound from the public reference (initial tick 0).
        uint256 limit = buyDirection
            ? (uint256(Q96) * 984885780179610473 + 1e18 - 1) / 1e18
            : uint256(Q96) * 1014889156509221946 / 1e18;
        assertEq(spot, limit);
        vm.warp(block.timestamp + 3600);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(spot)));
        (uint256 nextSpent, uint256 nextBurned) = hook.executeBatch();
        assertGt(nextSpent, 0, "unfilled remainder deadlocked");
        assertGt(nextBurned, 0);
        assertEq(hook.pending(), before - spent - nextSpent);
        _assertSettled();
    }

    function test_CooldownBoundaryAndEmptyBatch() public {
        uint256 initializedAt = block.timestamp;
        vm.warp(initializedAt + 3599);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.executeBatch();
        vm.warp(initializedAt + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent + burned, 0);
        assertEq(hook.lastBatch(), initializedAt + 3600);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.executeBatch();
    }

    function test_TimeWeightedReferenceExcludesSameTimestampManipulation() public {
        vm.warp(block.timestamp + 900);
        _swap(true, true, 100_000 ether, TickMath.getSqrtPriceAtTick(buyDirection ? int24(-100) : int24(100)));
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(hook.referencePrice(), Q96, "new spot got historical weight");
        vm.warp(block.timestamp + 2700);
        int256 numerator = int256(tick) * 2700;
        int256 mean = numerator / 3600;
        if (numerator < 0 && numerator % 3600 != 0) --mean;
        uint160 referenceBefore = hook.referencePrice();
        assertEq(referenceBefore, TickMath.getSqrtPriceAtTick(int24(mean)));
        _swap(false, true, 10_000 ether, 0);
        assertEq(hook.referencePrice(), referenceBefore);
    }

    function test_OutsideLimitSkipsThenRecoversWithoutSpending() public {
        IERC20(IMD).transfer(address(hook), 1000 ether);
        vm.warp(block.timestamp + 3600);
        _swap(
            true, true, 1_000_000 ether, TickMath.getSqrtPriceAtTick(buyDirection ? int24(-500) : int24(500))
        );
        assertEq(hook.referencePrice(), Q96);
        uint256 before = hook.pending();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent + burned, 0);
        assertEq(hook.pending(), before);
        vm.warp(block.timestamp + 3600);
        (spent, burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertEq(hook.pending(), before - spent);
    }

    function test_CannotBatchInsideSomeoneElsesUnlock() public {
        vm.warp(block.timestamp + 3600);
        actor.tryNestedBatch(key);
        assertTrue(actor.nestedCallRefused());
    }

    function test_RuntimeAndCreationSizeAndNoEscapeOpcodes() public view {
        assertLe(type(SIMDTESTHook).creationCode.length + 64, 49152);
        assertLe(address(hook).code.length, 24576);
        _checkOpcodes(address(hook).code);
        _checkOpcodes(address(token).code);
    }

    function _checkOpcodes(bytes memory code) private pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else require(op != 0xf4 && op != 0xff && op != 0xf2, "escape opcode");
        }
    }
}

contract TokenIsCurrency0Test is HookScenarios {
    function setUp() public {
        _setup(false, false, true);
    }
}

contract TokenIsCurrency1Test is HookScenarios {
    function setUp() public {
        _setup(false, true, true);
    }
}

contract FreshManagerTest is LaunchFixture {
    function setUp() public {
        _setup(false, false, false);
    }

    function test_TokenOnlyLiquidityExactOutputBuyCollectsIMDFeeBeforeInputArrives() public {
        // Token is currency0: position above current price deposits token only.
        actor.liquidity(key, 60, 600, 10_000_000 ether);
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
        _checkFee(true, false, 1000 ether, 0, false);
        assertGt(hook.pending(), 0);
        vm.warp(block.timestamp + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(burned, 0);
    }

    function test_ZeroLiquiditySwapAndBatchHaveZeroFeesAndNoDeadlock() public {
        _checkFee(true, true, 1000 ether, Q96 * 10001 / 10000, false);
        assertEq(hook.pending() + hook.pendingBurn(), 0);
        IERC20(IMD).transfer(address(hook), 1000 ether);
        vm.warp(block.timestamp + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent + burned, 0);
        assertEq(hook.pending(), 1000 ether);
        _assertSettled();
    }
}
