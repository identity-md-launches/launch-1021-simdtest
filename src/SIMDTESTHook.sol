// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable, single-pool fee collector and permissionless bounded buyback.
/// @dev Fees are ERC-6909 currency claims OWNED by this hook, avoiding token transfers
///      before the router settles. Claims remain backed by the PoolManager's reserves.
contract SIMDTESTHook is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BATCH_BPS = 2500;
    uint256 public constant PRICE_LIMIT_BPS = 300;
    uint256 public constant BATCH_INTERVAL = 3600;
    uint24 public constant LP_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 2);

    IPoolManager public immutable poolManager;
    address public immutable token;
    PoolId public immutable poolId;
    bool public immutable pairedIsCurrency0;

    bool public initialized;
    uint256 public lastBatch;
    uint256 public epochStart;
    uint256 private observedAt;
    int24 private observedTick;
    int256 private cumulativeTick;
    uint8 private operation; // 0 idle, 1 sweep, 2 batch; also guards external token calls

    error OnlyPoolManager();
    error InvalidDeployment();
    error WrongPool();
    error NotInitialized();
    error BatchTooSoon();
    error SeparateUnlockRequired();
    error UnexpectedUnlock();
    error UnrepresentableFee();

    event FeeAccrued(address indexed currency, uint256 amount);
    event Swept(uint256 amount);
    event BatchExecuted(
        uint256 budget, uint256 spent, uint256 burned, uint160 referenceX96, uint160 limitX96
    );

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_).code.length == 0 || token_.code.length == 0 || token_ == IMD) {
            revert InvalidDeployment();
        }
        poolManager = manager_;
        token = token_;
        pairedIsCurrency0 = IMD < token_;
        poolId = poolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier separateUnlock(uint8 action) {
        if (operation != 0 || poolManager.isUnlocked()) revert SeparateUnlockRequired();
        operation = action;
        _;
        operation = 0;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(pairedIsCurrency0 ? IMD : token),
            currency1: Currency.wrap(pairedIsCurrency0 ? token : IMD),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) {
            revert WrongPool();
        }
        initialized = true;
        observedTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        observedAt = block.timestamp;
        epochStart = block.timestamp;
        lastBatch = block.timestamp;
        return IHooks.beforeInitialize.selector;
    }

    /// @dev No specified-side reservation and no LP fee override, including on partial fills.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 magnitude;
        unchecked {
            magnitude = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);
        }
        if (magnitude > uint256(type(int256).max) - magnitude / 100) revert UnrepresentableFee();
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128 fee) {
        _observe();
        // Core skips callbacks for swaps initiated by the hook; retain an explicit exemption.
        if (sender == address(this)) return (IHooks.afterSwap.selector, 0);
        bool unspecifiedIs0 = params.zeroForOne != (params.amountSpecified < 0);
        int256 filled = unspecifiedIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 amount = uint256(filled < 0 ? -filled : filled) / 100;
        // abs(int128.min) / 100 fits int128; round DOWN to avoid taxing zero/dust fills.
        fee = int128(int256(amount));
        if (amount != 0) {
            Currency currency = unspecifiedIs0 ? key.currency0 : key.currency1;
            poolManager.mint(address(this), currency.toId(), amount);
            emit FeeAccrued(Currency.unwrap(currency), amount);
        }
        return (IHooks.afterSwap.selector, fee);
    }

    /// @notice IMD owned by this hook, including claims and unsolicited ERC-20 donations.
    function pending() public view returns (uint256) {
        return _holdings(IMD);
    }

    /// @notice Launched tokens available to sweep, including claims and donations.
    function pendingBurn() public view returns (uint256) {
        return _holdings(token);
    }

    /// @notice Geometric time-weighted reference, expressed as sqrt(currency1/currency0) Q96.
    /// @dev Average liquid tick since initialization or the last batch that spent IMD. Such batches
    ///      are at least an hour apart. Empty attempts preserve history; same-timestamp changes have no weight.
    function referencePrice() public view returns (uint160) {
        if (!initialized) return 0;
        uint256 elapsed = block.timestamp - epochStart;
        int256 mean = observedTick;
        if (elapsed != 0) {
            int256 sum = cumulativeTick + int256(observedTick) * int256(block.timestamp - observedAt);
            mean = sum / int256(elapsed);
            if (sum < 0 && sum % int256(elapsed) != 0) --mean;
        }
        return TickMath.getSqrtPriceAtTick(int24(mean));
    }

    /// @notice Burns every available launched token by sending it to the fixed dead address.
    function sweep() external separateUnlock(1) returns (uint256 amount) {
        uint256 claims = _claims(token);
        uint256 direct = Currency.wrap(token).balanceOfSelf();
        amount = claims + direct;
        if (claims != 0) poolManager.unlock(abi.encode(claims));
        if (direct != 0) Currency.wrap(token).transfer(BURN, direct);
        emit Swept(amount);
    }

    /// @notice At most 25% of accrued IMD per hour; returns the actual partial fill.
    function executeBatch() external separateUnlock(2) returns (uint256 spent, uint256 burned) {
        if (!initialized) revert NotInitialized();
        if (block.timestamp - lastBatch < BATCH_INTERVAL) revert BatchTooSoon();
        uint160 referenceX96 = referencePrice();
        uint160 limitX96 = _priceLimit(referenceX96);
        (uint160 spot,,,) = poolManager.getSlot0(poolId);
        // Tighten against current executable price as well as the TWAP. Empty-region spot can
        // move for free; use the retained liquid observation there so launch liquidity is reachable.
        uint160 spotLimitX96 = _priceLimit(
            poolManager.getLiquidity(poolId) != 0 ? spot : TickMath.getSqrtPriceAtTick(observedTick)
        );
        if (pairedIsCurrency0 ? spotLimitX96 > limitX96 : spotLimitX96 < limitX96) {
            limitX96 = spotLimitX96;
        }
        uint256 budget = pending() / 4;
        // Core represents each currency delta as int128. Limit exceptionally large donations.
        if (budget > uint256(uint128(type(int128).max))) budget = uint256(uint128(type(int128).max));
        bool room = pairedIsCurrency0 ? spot > limitX96 : spot < limitX96;
        if (budget != 0 && room) {
            (spent, burned) = abi.decode(poolManager.unlock(abi.encode(budget, limitX96)), (uint256, uint256));
        }
        // Empty attempts neither consume the hourly slot nor erase the TWAP's history.
        // Core suppresses self-swap callbacks; record a filled batch's liquid post-swap tick.
        if (spent != 0) {
            lastBatch = block.timestamp;
            if (poolManager.getLiquidity(poolId) != 0) (, observedTick,,) = poolManager.getSlot0(poolId);
            cumulativeTick = 0;
            observedAt = block.timestamp;
            epochStart = block.timestamp;
        }
        emit BatchExecuted(budget, spent, burned, referenceX96, limitX96);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (operation == 1) {
            uint256 amount = abi.decode(data, (uint256));
            poolManager.burn(address(this), uint160(token), amount);
            poolManager.take(Currency.wrap(token), BURN, amount);
            return "";
        }
        if (operation != 2) revert UnexpectedUnlock();
        (uint256 budget, uint160 limit) = abi.decode(data, (uint256, uint160));
        BalanceDelta delta =
            poolManager.swap(poolKey(), SwapParams(pairedIsCurrency0, -int256(budget), limit), "");
        uint256 spent = uint256(-int256(pairedIsCurrency0 ? delta.amount0() : delta.amount1()));
        uint256 bought = uint256(int256(pairedIsCurrency0 ? delta.amount1() : delta.amount0()));
        // Burn ONLY the claims actually spent. Unfilled budget stays available to the next batch.
        uint256 claims = _claims(IMD);
        uint256 fromClaims = spent < claims ? spent : claims;
        if (fromClaims != 0) poolManager.burn(address(this), uint160(IMD), fromClaims);
        if (spent > fromClaims) {
            Currency pair = Currency.wrap(IMD);
            poolManager.sync(pair);
            pair.transfer(address(poolManager), spent - fromClaims);
            poolManager.settle();
        }
        if (bought != 0) poolManager.take(Currency.wrap(token), BURN, bought);
        return abi.encode(spent, bought);
    }

    function _observe() private {
        cumulativeTick += int256(observedTick) * int256(block.timestamp - observedAt);
        observedAt = block.timestamp;
        // Core can traverse empty liquidity to any price limit, even on a zero fill.
        // Carry the last liquid (or initialization) tick forward instead of weighting that void.
        if (poolManager.getLiquidity(poolId) != 0) (, observedTick,,) = poolManager.getSlot0(poolId);
    }

    function _claims(address currency) private view returns (uint256) {
        return poolManager.balanceOf(address(this), uint160(currency));
    }

    function _holdings(address currency) private view returns (uint256) {
        return _claims(currency) + Currency.wrap(currency).balanceOfSelf();
    }

    function _priceLimit(uint160 referenceX96) private view returns (uint160) {
        // 300 bps in pool PRICE, not sqrt price. Factors are conservatively rounded:
        // ceil(sqrt(0.97)*1e18) and floor(sqrt(1.03)*1e18).
        uint256 limit = pairedIsCurrency0
            ? FullMath.mulDivRoundingUp(referenceX96, 984885780179610473, 1e18)
            : FullMath.mulDiv(referenceX96, 1014889156509221946, 1e18);
        if (limit <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(limit);
    }
}
