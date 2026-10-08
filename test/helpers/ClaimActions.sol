// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Deposits fully backed ERC-6909 donations and probes nested keeper calls.
contract ClaimActions is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(SIMDTESTHook hook, Currency currency, uint256 amount) external {
        manager.unlock(abi.encode(uint8(0), msg.sender, hook, currency, amount));
    }

    function probeNested(SIMDTESTHook hook, bool sweep) external {
        manager.unlock(
            abi.encode(sweep ? uint8(1) : uint8(2), msg.sender, hook, Currency.wrap(hook.token()), uint256(0))
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address payer, SIMDTESTHook hook, Currency currency, uint256 amount) =
            abi.decode(data, (uint8, address, SIMDTESTHook, Currency, uint256));
        if (action == 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount));
            manager.settle();
            manager.mint(address(hook), currency.toId(), amount);
        } else {
            (bool ok, bytes memory reason) = address(hook)
                .call(action == 1 ? abi.encodeCall(hook.sweep, ()) : abi.encodeCall(hook.executeBatch, ()));
            require(!ok, "keeper function entered an existing unlock");
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(SIMDTESTHook.SeparateUnlockRequired.selector)),
                "unexpected nested-call failure"
            );
        }
        return "";
    }
}
