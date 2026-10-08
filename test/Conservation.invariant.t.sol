// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {ClaimActions} from "./helpers/ClaimActions.sol";
import {SwapEvidence} from "./helpers/SwapEvidence.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LaunchHandler is Test {
    using StateLibrary for IPoolManager;

    SIMDTESTHook public immutable hook;
    PoolActor public immutable actor;
    ClaimActions public immutable donor;
    IPoolManager public immutable manager;
    PoolKey internal key;
    uint256 public pairedFees;
    uint256 public tokenFees;
    uint256 public pairedDonations;
    uint256 public tokenDonations;
    uint256 public spent;
    uint256 public bought;
    uint256 public swept;
    uint256 public tradeCalls;
    uint256 public partialFills;
    uint256 public batchCalls;
    uint256 public sweepCalls;
    uint256 public donationCalls;

    constructor(SIMDTESTHook hook_, PoolActor actor_) {
        hook = hook_;
        actor = actor_;
        manager = hook_.poolManager();
        donor = new ClaimActions(manager);
        key = hook_.poolKey();
        IERC20(hook_.token()).approve(address(actor_), type(uint256).max);
        IERC20(hook_.IMD()).approve(address(actor_), type(uint256).max);
        IERC20(hook_.token()).approve(address(donor), type(uint256).max);
        IERC20(hook_.IMD()).approve(address(donor), type(uint256).max);
    }

    function trade(bool direction, bool exactInput, uint256 amount) external {
        amount = bound(amount, 1, 1000 ether);
        _trade(
            direction,
            exactInput,
            amount,
            direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function limitedTrade(bool direction, bool exactInput, uint24 distance) external {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        // At a downward tick crossing slot0.tick can be one below the price's tick.
        // Derive limits from sqrtPrice to keep the next upward limit strictly above spot.
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        int24 ticks = int24(uint24(bound(distance, 1, 10)));
        uint160 limit = TickMath.getSqrtPriceAtTick(direction ? tick - ticks : tick + ticks);
        // Requests exceed available funds; only the small price-limited fill may be charged.
        _trade(direction, exactInput, 10_000_000 ether, limit);
        ++partialFills;
    }

    function _trade(bool direction, bool exactInput, uint256 amount, uint160 limit) private {
        uint256 deadBefore = IERC20(hook.token()).balanceOf(hook.BURN());
        vm.recordLogs();
        BalanceDelta net =
            actor.swap(key, SwapParams(direction, exactInput ? -int256(amount) : int256(amount), limit));
        SwapEvidence.Receipt memory receipt =
            SwapEvidence.read(vm.getRecordedLogs(), address(manager), key.toId());
        assertEq(receipt.lpFee, 12500);
        assertEq(receipt.sender, address(actor));
        bool unspecified0 = direction != exactInput;
        int256 raw = unspecified0 ? int256(receipt.delta.amount0()) : int256(receipt.delta.amount1());
        uint256 fee = uint256(raw < 0 ? -raw : raw) / 100;
        assertEq(
            int256(net.amount0()), int256(receipt.delta.amount0()) - (unspecified0 ? int256(fee) : int256(0))
        );
        assertEq(
            int256(net.amount1()), int256(receipt.delta.amount1()) - (unspecified0 ? int256(0) : int256(fee))
        );
        if (Currency.unwrap(unspecified0 ? key.currency0 : key.currency1) == hook.IMD()) pairedFees += fee;
        else tokenFees += fee;
        assertEq(IERC20(hook.token()).balanceOf(hook.BURN()), deadBefore, "swap spent accrued fees");
        int256 specified = unspecified0 ? int256(receipt.delta.amount1()) : int256(receipt.delta.amount0());
        if (amount == 10_000_000 ether) {
            assertLt(uint256(specified < 0 ? -specified : specified), amount);
        }
        ++tradeCalls;
    }

    function donate(bool paired, bool asClaims, uint256 amount) external {
        amount = bound(amount, 0, 1000 ether);
        address currency = paired ? hook.IMD() : hook.token();
        if (asClaims) donor.donate(hook, Currency.wrap(currency), amount);
        else IERC20(currency).transfer(address(hook), amount);
        if (paired) pairedDonations += amount;
        else tokenDonations += amount;
        ++donationCalls;
    }

    function elapse(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 7200));
    }

    function batch() external {
        uint256 last = hook.lastBatch();
        if (vm.getBlockTimestamp() - last < 3600) {
            vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
            hook.executeBatch();
            assertEq(hook.lastBatch(), last);
            return;
        }
        uint256 available = hook.pending();
        uint256 tokenFeesBefore = hook.pendingBurn();
        uint256 deadBefore = IERC20(hook.token()).balanceOf(hook.BURN());
        vm.recordLogs();
        (uint256 spentNow, uint256 boughtNow) = hook.executeBatch();
        require(spentNow <= available / 4, "budget exceeded");
        assertEq(hook.lastBatch(), vm.getBlockTimestamp());
        assertEq(hook.pending(), available - spentNow);
        assertEq(hook.pendingBurn(), tokenFeesBefore, "batch charged a hook fee");
        assertEq(IERC20(hook.token()).balanceOf(hook.BURN()), deadBefore + boughtNow);
        if (spentNow != 0) {
            SwapEvidence.Receipt memory receipt =
                SwapEvidence.read(vm.getRecordedLogs(), address(manager), key.toId());
            bool buy = hook.pairedIsCurrency0();
            assertEq(receipt.sender, address(hook));
            assertEq(receipt.lpFee, 12500);
            assertEq(spentNow, uint256(-int256(buy ? receipt.delta.amount0() : receipt.delta.amount1())));
            assertEq(boughtNow, uint256(int256(buy ? receipt.delta.amount1() : receipt.delta.amount0())));
        }
        spent += spentNow;
        bought += boughtNow;
        ++batchCalls;
    }

    function sweep() external {
        uint256 available = hook.pendingBurn();
        uint256 pairBefore = hook.pending();
        uint256 deadBefore = IERC20(hook.token()).balanceOf(hook.BURN());
        uint256 amount = hook.sweep();
        assertEq(amount, available);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.pending(), pairBefore);
        assertEq(IERC20(hook.token()).balanceOf(hook.BURN()), deadBefore + amount);
        swept += amount;
        ++sweepCalls;
    }
}

abstract contract ConservationInvariantScenarios is LaunchFixture {
    LaunchHandler internal handler;

    function setUp() public {
        _setup(false, tokenHigh(), true);
        handler = new LaunchHandler(hook, actor);
        token.transfer(address(handler), 1_000_000 ether);
        IERC20(IMD).transfer(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LaunchHandler.trade.selector;
        selectors[1] = LaunchHandler.elapse.selector;
        selectors[2] = LaunchHandler.batch.selector;
        selectors[3] = LaunchHandler.sweep.selector;
        selectors[4] = LaunchHandler.limitedTrade.selector;
        selectors[5] = LaunchHandler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function tokenHigh() internal pure virtual returns (bool);

    function invariant_AllFeeAssetsAreAccountedFor() public view {
        assertEq(hook.pending() + handler.spent(), handler.pairedFees() + handler.pairedDonations());
        assertEq(hook.pendingBurn() + handler.swept(), handler.tokenFees() + handler.tokenDonations());
        assertEq(token.balanceOf(DEAD), handler.swept() + handler.bought());
        assertEq(token.totalSupply(), 1e27);
        assertEq(
            hook.pending(),
            manager.balanceOf(address(hook), uint160(IMD)) + IERC20(IMD).balanceOf(address(hook))
        );
        assertEq(
            hook.pendingBurn(),
            manager.balanceOf(address(hook), uint160(address(token))) + token.balanceOf(address(hook))
        );
        assertLe(manager.balanceOf(address(hook), uint160(IMD)), IERC20(IMD).balanceOf(address(manager)));
        assertLe(manager.balanceOf(address(hook), uint160(address(token))), token.balanceOf(address(manager)));
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(handler))
                + token.balanceOf(address(manager)) + token.balanceOf(address(hook)) + token.balanceOf(DEAD),
            1e27
        );
        assertEq(
            IERC20(IMD).balanceOf(address(this)) + IERC20(IMD).balanceOf(address(handler))
                + IERC20(IMD).balanceOf(address(manager)) + IERC20(IMD).balanceOf(address(hook)),
            100_000_000 ether
        );
        assertEq(token.balanceOf(address(actor)), 0);
        assertEq(IERC20(IMD).balanceOf(address(actor)), 0);
        _assertSettled();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ConservationInvariantTest is ConservationInvariantScenarios {
    function tokenHigh() internal pure override returns (bool) {
        return false;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ConservationToken1InvariantTest is ConservationInvariantScenarios {
    function tokenHigh() internal pure override returns (bool) {
        return true;
    }
}
