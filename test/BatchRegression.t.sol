// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Regressions use the real core and exercise both token orderings.
abstract contract BatchRegressionScenarios is LaunchFixture {
    using StateLibrary for IPoolManager;

    function _seedTokenOnly() internal {
        actor.liquidity(
            key,
            buyDirection ? int24(-600) : int24(60),
            buyDirection ? int24(-60) : int24(600),
            10_000_000 ether
        );
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0);
    }

    function test_ZeroFillVoidDoesNotPoisonReferenceOrBlockBatch() public {
        _seedTokenOnly();
        IERC20(IMD).transfer(address(hook), 1000 ether);
        vm.warp(block.timestamp + 1);
        BalanceDelta delta = _swap(false, true, 1, 0);
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
        vm.warp(block.timestamp + 3599);
        assertEq(hook.referencePrice(), Q96, "untraded tick entered reference");
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 250 ether, "empty-region spot must not prevent reaching offered tokens");
        assertGt(burned, 0);
        assertEq(hook.pending(), 750 ether);
        _assertSettled();
    }

    function test_VoidExcursionThenBuyerRestoresSpot() public {
        _seedTokenOnly();
        IERC20(IMD).transfer(address(hook), 1000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 1);
        assertEq(BalanceDelta.unwrap(_swap(false, true, 1, 0)), 0);
        vm.warp(start + 13);
        _swap(true, true, 1000 ether, 0);
        assertGt(manager.getLiquidity(key.toId()), 0);
        vm.warp(start + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 250 ether);
        assertGt(burned, 0);
        _assertSettled();
    }

    function test_NonzeroFillThatExhaustsLiquidityDoesNotRecordVoidTick() public {
        _seedTokenOnly();
        _swap(true, true, 1000 ether, 0);
        (, int24 liquidTick,,) = manager.getSlot0(key.toId());
        vm.warp(block.timestamp + 1);
        BalanceDelta delta = _swap(false, true, 10_000 ether, 0);
        assertTrue(BalanceDelta.unwrap(delta) != 0, "must drain actual IMD first");
        assertEq(manager.getLiquidity(key.toId()), 0);
        vm.warp(block.timestamp + 3599);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(liquidTick));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(burned, 0);
        _assertSettled();
    }

    function test_EmptyPoolAttemptsPreserveReferenceAndSlot() public {
        IERC20(IMD).transfer(address(hook), 1000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent + burned, 0);
        assertEq(hook.referencePrice(), Q96);
        assertEq(hook.epochStart(), start);
        assertEq(hook.lastBatch(), start);
        (spent, burned) = hook.executeBatch();
        assertEq(spent + burned, 0);
        assertEq(hook.pending(), 1000 ether);
        assertEq(hook.referencePrice(), Q96);
        assertEq(hook.epochStart(), start);
        assertEq(hook.lastBatch(), start);
        _assertSettled();
    }

    function _seedDrift() internal {
        actor.liquidity(key, -12000, 12000, 10_000_000 ether);
        IERC20(IMD).transfer(address(hook), 2_000_000 ether);
        vm.warp(block.timestamp + 3000);
        _swap(
            false,
            true,
            10_000_000 ether,
            TickMath.getSqrtPriceAtTick(buyDirection ? int24(2000) : int24(-2000))
        );
        vm.warp(block.timestamp + 600);
    }

    function test_DriftedReferenceCannotAllowMoreThanThreePercentSpotImpact() public {
        _seedDrift();
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        uint256 pendingBefore = hook.pending();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        uint256 priceRatio =
            FullMath.mulDiv(afterPrice, uint256(afterPrice) * 1e18 / beforePrice, beforePrice);
        emit log_named_uint("price ratio (1e18)", priceRatio);
        assertGt(spent, 0);
        assertGt(burned, 0);
        if (buyDirection) assertGe(priceRatio, 0.97e18);
        else assertLe(priceRatio, 1.03e18);
        assertLt(spent, pendingBefore / 4);
        assertEq(hook.pending(), pendingBefore - spent);
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DriftedBatchRespectsSpotBandAndBudget(uint24 drift, uint16 timeBeforeSell) public {
        actor.liquidity(key, -12000, 12000, 10_000_000 ether);
        IERC20(IMD).transfer(address(hook), 20_000_000 ether);
        int24 ticks = int24(uint24(bound(drift, 1, 5000)));
        uint256 delay = bound(timeBeforeSell, 1, 3599);
        uint256 start = block.timestamp;
        vm.warp(start + delay);
        _swap(false, true, 10_000_000 ether, TickMath.getSqrtPriceAtTick(buyDirection ? ticks : -ticks));
        vm.warp(start + 3600);
        uint256 pendingBefore = hook.pending();
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        (uint256 spent, uint256 burned) = hook.executeBatch();
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        uint256 ratio = FullMath.mulDiv(afterPrice, uint256(afterPrice) * 1e18 / beforePrice, beforePrice);
        if (buyDirection) assertGe(ratio, 0.97e18);
        else assertLe(ratio, 1.03e18);
        assertGt(spent, 0);
        assertLe(spent, pendingBefore / 4);
        assertGt(burned, 0);
        assertEq(hook.pending(), pendingBefore - spent);
        assertEq(token.balanceOf(DEAD), burned);
        _assertSettled();
    }

    function _sandwich(int24 targetTick) internal {
        uint256 pairBefore = IERC20(IMD).balanceOf(address(this));
        uint256 tokensBefore = token.balanceOf(address(this));
        _swap(true, true, 10_000_000 ether, TickMath.getSqrtPriceAtTick(targetTick));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(burned, 0);
        _swap(false, true, token.balanceOf(address(this)) - tokensBefore, 0);
        int256 profit = int256(IERC20(IMD).balanceOf(address(this))) - int256(pairBefore);
        emit log_named_int("sandwich profit in IMD wei", profit);
        assertLt(profit, 0, "stale-reference sandwich is profitable");
        assertEq(token.balanceOf(address(this)), tokensBefore);
        _assertSettled();
    }

    function test_LargeSandwichAfterDriftLosesMoney() public {
        _seedDrift();
        _sandwich(buyDirection ? int24(1100) : int24(-1100));
    }

    function test_SmallSandwichAfterDriftLosesMoney() public {
        _seedDrift();
        _sandwich(buyDirection ? int24(1900) : int24(-1900));
    }

    function test_SandwichWithoutDriftControlLosesMoney() public {
        actor.liquidity(key, -12000, 12000, 10_000_000 ether);
        IERC20(IMD).transfer(address(hook), 2_000_000 ether);
        vm.warp(block.timestamp + 3600);
        _sandwich(buyDirection ? int24(-100) : int24(100));
    }

    function test_ZeroFillGriefCannotConsumeSlotOrResetTwap() public {
        actor.liquidity(key, -12000, 12000, 1_000_000 ether);
        IERC20(IMD).transfer(address(hook), 400_000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 3600);
        uint256 snapshot = vm.snapshotState();
        (uint256 controlSpent,) = hook.executeBatch();
        assertGt(controlSpent, 0);
        vm.revertToState(snapshot);
        uint256 tokensBefore = token.balanceOf(address(this));
        _swap(true, true, 20_000 ether, 0);
        uint256 pendingBefore = hook.pending();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent + burned, 0);
        assertEq(hook.pending(), pendingBefore);
        _swap(false, true, token.balanceOf(address(this)) - tokensBefore, 0);
        // Retry in the same block must succeed, with the original time-weighted history intact.
        (spent, burned) = hook.executeBatch();
        assertGt(spent, 0, "zero-fill attempt consumed the hourly slot");
        assertGt(burned, 0);
        assertEq(hook.lastBatch(), block.timestamp);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.executeBatch();
        _assertSettled();
    }

    function test_RepeatedOutOfBandAttemptsPreserveEpochAndHourlySlot() public {
        actor.liquidity(key, -12000, 12000, 1_000_000 ether);
        IERC20(IMD).transfer(address(hook), 400_000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 3600);
        _swap(true, true, 20_000 ether, 0);
        for (uint256 i; i < 3; ++i) {
            (uint256 spent, uint256 burned) = hook.executeBatch();
            assertEq(spent + burned, 0, "retry bypassed TWAP guard");
            assertEq(hook.lastBatch(), start);
            assertEq(hook.epochStart(), start);
            assertEq(hook.referencePrice(), Q96);
        }
    }

    // Advisory findings below document existing deployment and rounding choices.
    function test_NonatomicDeploymentAllowsFirstInitializer() public {
        (, bytes32 salt) = new MineHook().run(address(this), manager, address(token), 200_000);
        SIMDTESTHook other = new SIMDTESTHook{salt: salt}(manager, address(token));
        PoolKey memory otherKey = other.poolKey();
        uint160 openingPrice = TickMath.getSqrtPriceAtTick(50000);
        vm.prank(makeAddr("third party initializer"));
        manager.initialize(otherKey, openingPrice);
        assertTrue(other.initialized());
        assertEq(other.referencePrice(), openingPrice);
        vm.expectRevert();
        manager.initialize(otherKey, Q96);
    }

    function test_QuietPoolReanchorsAtEachFilledBatch() public {
        actor.liquidity(key, -600, 600, 10_000_000 ether);
        IERC20(IMD).transfer(address(hook), 50_000_000 ether);
        vm.warp(block.timestamp + 3600);
        hook.executeBatch();
        (uint160 firstPrice, int24 firstTick,,) = manager.getSlot0(key.toId());
        vm.warp(block.timestamp + 3600);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(firstTick));
        hook.executeBatch();
        (uint160 secondPrice,,,) = manager.getSlot0(key.toId());
        if (buyDirection) assertLt(secondPrice, firstPrice);
        else assertGt(secondPrice, firstPrice);
    }

    function test_FractionalMeanTickRoundsDown() public {
        actor.liquidity(key, -600, 600, 10_000_000 ether);
        vm.warp(block.timestamp + 1800);
        // In both currency orderings move zeroForOne to tick -1, without crossing an initialized tick.
        _swap(buyDirection, true, 1000 ether, TickMath.getSqrtPriceAtTick(-1));
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, -1);
        vm.warp(block.timestamp + 1800);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(-1));
    }

    function test_DustFeesRoundDown() public {
        actor.liquidity(key, -600, 600, 10_000_000 ether);
        for (uint256 i = 1; i < 100; ++i) {
            _checkFee(false, true, i, 0, false);
        }
        assertEq(hook.pending(), 0);
        _checkFee(true, false, 199, 0, false);
        assertEq(hook.pending(), 2);
    }

    function test_CoreTickBoundaryConventionIsPreserved() public {
        actor.liquidity(key, -600, 600, 10_000_000 ether);
        actor.liquidity(key, -60, 60, 1_000_000 ether);
        vm.warp(block.timestamp + 1800);
        uint160 boundary = TickMath.getSqrtPriceAtTick(-60);
        _swap(buyDirection, true, 100_000 ether, boundary);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(price, boundary);
        assertEq(tick, -61);
        vm.warp(block.timestamp + 1800);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(-31));
    }
}

contract BatchRegressionToken0Test is BatchRegressionScenarios {
    function setUp() public {
        _setup(false, false, false);
    }
}

contract BatchRegressionToken1Test is BatchRegressionScenarios {
    function setUp() public {
        _setup(false, true, false);
    }
}
