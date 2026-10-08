// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookScenarios} from "./SIMDTESTHook.t.sol";
import {AdversarialHookScenarios} from "./AdversarialHook.t.sol";

/// @notice Run with forge test --match-contract MainnetForkTest --fork-url <RPC> --fork-block-number <block>.
/// @dev No environment access or implicit network. Offline tests report an explicit skip.
abstract contract MainnetForkScenarios is HookScenarios, AdversarialHookScenarios {
    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true, "Supply a mainnet fork via forge --fork-url to rehearse against deployed contracts");
            return;
        }
        _setup(true, tokenHigh(), true);
    }

    function tokenHigh() internal pure virtual returns (bool);
}

contract MainnetForkTest is MainnetForkScenarios {
    function tokenHigh() internal pure override returns (bool) {
        return false;
    }
}

contract MainnetForkToken1Test is MainnetForkScenarios {
    function tokenHigh() internal pure override returns (bool) {
        return true;
    }
}
