// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {ClaimActions} from "./helpers/ClaimActions.sol";
import {SwapEvidence} from "./helpers/SwapEvidence.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Also inherited by the opt-in mainnet fork suite.
abstract contract AdversarialHookScenarios is LaunchFixture {
    using StateLibrary for IPoolManager;

    event Swept(uint256 amount);

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FailedSettlementRollsBackClaimsAndOracle(bool exactInput, uint256 amount) public {
        amount = bound(amount, 100, 1000 ether);
        _swap(true, true, 1000 ether, 0);
        vm.warp(vm.getBlockTimestamp() + 1800);
        uint256 pairBefore = hook.pending();
        uint256 burnBefore = hook.pendingBurn();
        uint160 referenceBefore = hook.referencePrice();
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 imdBefore = IERC20(IMD).balanceOf(address(this));
        token.approve(address(actor), 0);
        vm.expectPartialRevert(bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")));
        _swap(false, exactInput, amount, 0);
        assertEq(hook.pending(), pairBefore);
        assertEq(hook.pendingBurn(), burnBefore);
        assertEq(hook.referencePrice(), referenceBefore);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(token.balanceOf(address(this)), tokensBefore);
        assertEq(IERC20(IMD).balanceOf(address(this)), imdBefore);
        _assertSettled();
        token.approve(address(actor), type(uint256).max);
        _checkFee(false, exactInput, amount, 0, false);
    }

    /// @dev An enormous request is valid when the price limit bounds the actual fill.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_HugeRequestsStillChargeOnlyActualPartialFill(bool buy, bool exactInput, uint256 amount)
        public
    {
        amount = bound(amount, 1e30, uint256(type(int256).max) / 2);
        bool direction = buy ? buyDirection : !buyDirection;
        _checkFee(
            buy, exactInput, amount, TickMath.getSqrtPriceAtTick(direction ? int24(-1) : int24(1)), true
        );
    }

    function test_MixedClaimsAndDirectIMDSettleOnlyWhatBatchSpends() public {
        _swap(false, true, 1000 ether, 0);
        _swap(true, true, 1000 ether, 0);
        uint256 claims = manager.balanceOf(address(hook), uint160(IMD));
        assertGt(claims, 0);
        uint256 donation = claims * 8 + 3;
        IERC20(IMD).transfer(address(hook), donation);
        uint256 pendingTokenFees = hook.pendingBurn();
        uint256 budget = (claims + donation) / 4;
        vm.warp(vm.getBlockTimestamp() + 3600);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        vm.recordLogs();
        vm.prank(makeAddr("independent batch caller"));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        SwapEvidence.Receipt memory receipt =
            SwapEvidence.read(vm.getRecordedLogs(), address(manager), key.toId());
        assertEq(receipt.sender, address(hook), "batch must swap as the hook itself");
        assertEq(receipt.lpFee, 12500);
        assertEq(spent, budget);
        assertEq(spent, uint256(-int256(buyDirection ? receipt.delta.amount0() : receipt.delta.amount1())));
        assertEq(burned, uint256(int256(buyDirection ? receipt.delta.amount1() : receipt.delta.amount0())));
        assertGt(burned, 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), donation - (spent - claims));
        assertEq(hook.pending(), claims + donation - spent);
        assertEq(hook.pendingBurn(), pendingTokenFees);
        assertEq(token.balanceOf(DEAD), burned);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(receipt.tick));
        assertTrue(receipt.price != priceBefore, "batch did not move price");
        _assertSettled();
    }

    function test_DustSwapsAroundOnePercentRoundingBoundary() public {
        uint256[6] memory amounts = [uint256(1), 98, 99, 100, 101, 102];
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 i; i < amounts.length; ++i) {
                _checkFee(mode < 2, mode % 2 == 0, amounts[i], 0, false);
            }
        }
    }

    function test_PartialBatchPreservesUnspentClaimsForNextHour() public {
        ClaimActions donor = new ClaimActions(manager);
        IERC20(IMD).approve(address(donor), type(uint256).max);
        donor.donate(hook, Currency.wrap(IMD), 20_000_000 ether);
        _swap(true, true, 1000 ether, 0);
        uint256 tokenFees = hook.pendingBurn();
        vm.warp(vm.getBlockTimestamp() + 3600);
        uint160 referenceBefore = hook.referencePrice();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertLt(spent, 5_000_000 ether);
        assertGt(burned, 0, "partial fill rejected by an output minimum");
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 20_000_000 ether - spent);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(hook.pendingBurn(), tokenFees);
        assertEq(token.balanceOf(DEAD), burned);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        // Compare squared prices in bps, independently of the implementation's sqrt factors.
        uint256 priceSquaredBps = uint256(price) * price * 10_000;
        uint256 referenceSquared = uint256(referenceBefore) * referenceBefore;
        if (buyDirection) {
            assertGe(priceSquaredBps, referenceSquared * 9700);
            assertLt(priceSquaredBps, referenceSquared * 9701);
        } else {
            assertLe(priceSquaredBps, referenceSquared * 10300);
            assertGt(priceSquaredBps, referenceSquared * 10299);
        }
        vm.warp(vm.getBlockTimestamp() + 3600);
        (uint256 nextSpent, uint256 nextBurned) = hook.executeBatch();
        assertGt(nextSpent, 0, "unspent claims could not fund the next batch");
        assertGt(nextBurned, 0);
        assertEq(hook.pending(), 20_000_000 ether - spent - nextSpent);
        assertEq(token.balanceOf(DEAD), burned + nextBurned);
        _assertSettled();
    }

    function test_BackedClaimDonationsAreIncludedAndCannotBeStolen() public {
        ClaimActions donor = new ClaimActions(manager);
        token.approve(address(donor), type(uint256).max);
        IERC20(IMD).approve(address(donor), type(uint256).max);
        donor.donate(hook, Currency.wrap(address(token)), 1234);
        donor.donate(hook, Currency.wrap(IMD), 100 ether);
        token.transfer(address(hook), 7);
        assertEq(hook.pendingBurn(), 1241);
        assertEq(hook.pending(), 100 ether);
        address thief = makeAddr("claim thief");
        assertFalse(manager.isOperator(address(hook), thief));
        assertEq(manager.allowance(address(hook), thief, uint160(IMD)), 0);
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        manager.transferFrom(address(hook), thief, uint160(IMD), 1);
        assertEq(hook.pending(), 100 ether);
        vm.expectEmit(false, false, false, true, address(hook));
        emit Swept(1241);
        vm.prank(thief); // Can burn for everyone, never redirect to itself.
        assertEq(hook.sweep(), 1241);
        assertEq(token.balanceOf(thief), 0);
        assertEq(token.balanceOf(DEAD), 1241);
        assertEq(hook.pendingBurn(), 0);
        vm.warp(vm.getBlockTimestamp() + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 25 ether);
        assertGt(burned, 0);
        assertEq(hook.pending(), 75 ether);
        _assertSettled();
    }

    function test_FailedSweepRestoresClaimsAndAllowsImmediateRetry() public {
        _swap(true, true, 1000 ether, 0);
        token.transfer(address(hook), 17);
        uint256 before = hook.pendingBurn();
        uint256 claims = manager.balanceOf(address(hook), uint160(address(token)));
        bytes memory reason = abi.encodeWithSignature("Error(string)", "injected transfer failure");
        // The claim redemption succeeds first; only the subsequent direct transfer fails.
        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.transfer, (DEAD, 17)), reason);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(token),
                IERC20.transfer.selector,
                reason,
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        hook.sweep();
        vm.clearMockedCalls();
        assertEq(hook.pendingBurn(), before);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), claims);
        assertEq(token.balanceOf(DEAD), 0);
        _assertSettled();
        assertEq(hook.sweep(), before, "failed call left operation guard set");
        assertEq(hook.pendingBurn(), 0);
        assertEq(token.balanceOf(DEAD), before);
    }

    function test_FailedBatchRestoresBudgetOracleAndCooldownForRetry() public {
        _swap(false, true, 1000 ether, 0);
        uint256 claims = hook.pending();
        IERC20(IMD).transfer(address(hook), claims * 8);
        vm.warp(vm.getBlockTimestamp() + 3600);
        uint256 before = hook.pending();
        uint256 last = hook.lastBatch();
        uint256 epoch = hook.epochStart();
        uint160 referenceBefore = hook.referencePrice();
        (uint160 spotBefore,,,) = manager.getSlot0(key.toId());
        bytes memory reason = abi.encodeWithSignature("Error(string)", "injected transfer failure");
        vm.mockCallRevert(
            IMD, abi.encodeCall(IERC20.transfer, (address(manager), before / 4 - claims)), reason
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                IMD,
                IERC20.transfer.selector,
                reason,
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        hook.executeBatch();
        vm.clearMockedCalls();
        assertEq(hook.pending(), before);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), claims);
        assertEq(hook.lastBatch(), last);
        assertEq(hook.epochStart(), epoch);
        assertEq(hook.referencePrice(), referenceBefore);
        (uint160 spotAfter,,,) = manager.getSlot0(key.toId());
        assertEq(spotAfter, spotBefore);
        assertEq(token.balanceOf(DEAD), 0);
        _assertSettled();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, before / 4);
        assertGt(burned, 0);
        assertEq(hook.pending(), before - spent);
        assertEq(token.balanceOf(DEAD), burned);
    }

    function test_NestedSweepAndBatchCannotRedeemDuringAnotherUnlock() public {
        _swap(true, true, 1000 ether, 0);
        _swap(false, true, 1000 ether, 0);
        vm.warp(vm.getBlockTimestamp() + 3600);
        uint256 pairBefore = hook.pending();
        uint256 tokenBefore = hook.pendingBurn();
        ClaimActions caller = new ClaimActions(manager);
        caller.probeNested(hook, true);
        caller.probeNested(hook, false);
        assertEq(hook.pending(), pairBefore);
        assertEq(hook.pendingBurn(), tokenBefore);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(hook.sweep(), tokenBefore);
        (uint256 spent,) = hook.executeBatch();
        assertEq(spent, pairBefore / 4);
        _assertSettled();
    }

    function test_SubFourWeiBudgetStaysAccruedAndDoesNotBlockSweeping() public {
        IERC20(IMD).transfer(address(hook), 3);
        token.transfer(address(hook), 1);
        vm.warp(vm.getBlockTimestamp() + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 0);
        assertEq(burned, 0);
        assertEq(hook.pending(), 3);
        assertEq(hook.lastBatch(), vm.getBlockTimestamp());
        assertEq(hook.sweep(), 1);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.executeBatch();
        assertEq(token.balanceOf(DEAD), 1);
        _assertSettled();
    }
}

contract AdversarialToken0Test is AdversarialHookScenarios {
    function setUp() public {
        _setup(false, false, true);
    }
}

contract AdversarialToken1Test is AdversarialHookScenarios {
    function setUp() public {
        _setup(false, true, true);
    }
}
