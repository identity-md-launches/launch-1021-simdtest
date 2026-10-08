// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SIMDTEST} from "../../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {MineHook} from "../../script/MineHook.s.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolActor} from "./PoolActor.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract LaunchFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager internal manager;
    SIMDTEST internal token;
    SIMDTESTHook internal hook;
    PoolActor internal actor;
    PoolKey internal key;
    bool internal buyDirection;

    function _setup(bool forked, bool tokenHigh, bool seed) internal {
        _deploy(forked, tokenHigh);
        manager.initialize(key, Q96);
        if (seed) actor.liquidity(key, -600, 600, 10_000_000 ether);
    }

    function _deploy(bool forked, bool tokenHigh) internal {
        if (forked) {
            assertEq(block.chainid, 1);
            assertGt(MAINNET_MANAGER.code.length, 0, "fork lacks mainnet manager");
            assertGt(IMD.code.length, 0, "fork predates IMD deployment");
            manager = IPoolManager(MAINNET_MANAGER);
            // Fund only the test trader; the fork uses the actual IMD implementation and pool manager.
            deal(IMD, address(this), 100_000_000 ether);
        } else {
            manager = IPoolManager(address(new PoolManager(address(this))));
            vm.etch(IMD, address(new MockERC20("IMD fixture", "IMD", 0)).code);
            MockERC20(IMD).mint(address(this), 100_000_000 ether);
        }
        // Exercise BOTH currency orderings using a real, fixed-supply launch token.
        bytes32 tokenHash = keccak256(type(SIMDTEST).creationCode);
        for (uint256 i;; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), bytes32(i), tokenHash))))
            );
            if ((predicted > IMD) == tokenHigh) {
                token = new SIMDTEST{salt: bytes32(i)}();
                break;
            }
        }
        (address predictedHook, bytes32 salt) = new MineHook().run(address(this), manager, address(token), 0);
        hook = new SIMDTESTHook{salt: salt}(manager, address(token));
        assertEq(address(hook), predictedHook);
        assertEq(uint160(address(hook)) & 0x3fff, 0x20c4);
        key = hook.poolKey();
        buyDirection = hook.pairedIsCurrency0();
        actor = new PoolActor(manager);
        token.approve(address(actor), type(uint256).max);
        IERC20(IMD).approve(address(actor), type(uint256).max);
    }

    function _swap(bool buy, bool exactInput, uint256 amount, uint160 limit) internal returns (BalanceDelta) {
        bool direction = buy ? buyDirection : !buyDirection;
        if (limit == 0) limit = direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return actor.swap(key, SwapParams(direction, exactInput ? -int256(amount) : int256(amount), limit));
    }

    /// @dev Compare the caller's settled delta with the manager's PRE-hook Swap event.
    ///      This oracle is independent of the hook's fee event or counters.
    function _checkFee(bool buy, bool exactInput, uint256 amount, uint160 limit, bool expectPartial)
        internal
    {
        uint256[3] memory before = [hook.pending(), hook.pendingBurn(), token.balanceOf(DEAD)];
        vm.recordLogs();
        BalanceDelta net = _swap(buy, exactInput, amount, limit);
        BalanceDelta gross = _grossSwapDelta();
        bool unspecified0 = (buy ? buyDirection : !buyDirection) != exactInput;
        int256 raw = unspecified0 ? int256(gross.amount0()) : int256(gross.amount1());
        uint256 fee = uint256(raw < 0 ? -raw : raw) / 100;
        assertEq(int256(net.amount0()), int256(gross.amount0()) - (unspecified0 ? int256(fee) : int256(0)));
        assertEq(int256(net.amount1()), int256(gross.amount1()) - (unspecified0 ? int256(0) : int256(fee)));
        bool pairedFee = Currency.unwrap(unspecified0 ? key.currency0 : key.currency1) == IMD;
        assertEq(hook.pending() - before[0], pairedFee ? fee : 0);
        assertEq(hook.pendingBurn() - before[1], pairedFee ? 0 : fee);
        if (expectPartial) _assertPartial(gross, unspecified0, amount);
        assertEq(token.balanceOf(DEAD), before[2], "swap spent or swept fees");
        _assertSettled();
    }

    function _assertPartial(BalanceDelta gross, bool unspecified0, uint256 amount) private pure {
        int256 specified = unspecified0 ? int256(gross.amount1()) : int256(gross.amount0());
        uint256 filled = uint256(specified < 0 ? -specified : specified);
        assertGt(filled, 0);
        assertLt(filled, amount, "price limit did not cause partial fill");
    }

    function _grossSwapDelta() private view returns (BalanceDelta) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            (int128 gross0, int128 gross1,,,, uint24 lpFee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(lpFee, 12500, "static LP fee changed");
            return toBalanceDelta(gross0, gross1);
        }
        revert("no PoolManager swap event");
    }

    function _assertSettled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertFalse(manager.isUnlocked());
    }
}
