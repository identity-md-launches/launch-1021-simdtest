// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LaunchHandler is Test {
    SIMDTESTHook public immutable hook;
    PoolActor public immutable actor;
    PoolKey internal key;
    uint256 public pairedFees;
    uint256 public tokenFees;
    uint256 public spent;
    uint256 public bought;
    uint256 public swept;

    constructor(SIMDTESTHook hook_, PoolActor actor_) {
        hook = hook_;
        actor = actor_;
        key = hook_.poolKey();
        IERC20(hook_.token()).approve(address(actor_), type(uint256).max);
        IERC20(hook_.IMD()).approve(address(actor_), type(uint256).max);
    }

    function trade(bool direction, bool exactInput, uint256 amount) external {
        amount = bound(amount, 1, 1000 ether);
        uint256 pairBefore = hook.pending();
        uint256 tokenBefore = hook.pendingBurn();
        actor.swap(
            key,
            SwapParams(
                direction,
                exactInput ? -int256(amount) : int256(amount),
                direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        pairedFees += hook.pending() - pairBefore;
        tokenFees += hook.pendingBurn() - tokenBefore;
    }

    function elapse(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 7200));
    }

    function batch() external {
        if (block.timestamp - hook.lastBatch() < 3600) return;
        uint256 available = hook.pending();
        (uint256 spentNow, uint256 boughtNow) = hook.executeBatch();
        require(spentNow <= available / 4, "budget exceeded");
        spent += spentNow;
        bought += boughtNow;
    }

    function sweep() external {
        swept += hook.sweep();
    }
}

contract ConservationInvariantTest is LaunchFixture {
    LaunchHandler internal handler;

    function setUp() public {
        _setup(false, false, true);
        handler = new LaunchHandler(hook, actor);
        token.transfer(address(handler), 1_000_000 ether);
        IERC20(IMD).transfer(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = LaunchHandler.trade.selector;
        selectors[1] = LaunchHandler.elapse.selector;
        selectors[2] = LaunchHandler.batch.selector;
        selectors[3] = LaunchHandler.sweep.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_AllFeeAssetsAreAccountedFor() public view {
        assertEq(hook.pending() + handler.spent(), handler.pairedFees());
        assertEq(hook.pendingBurn() + handler.swept(), handler.tokenFees());
        assertEq(token.balanceOf(DEAD), handler.swept() + handler.bought());
        assertEq(token.totalSupply(), 1e27);
        _assertSettled();
    }
}
