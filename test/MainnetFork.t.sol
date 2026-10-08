// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookScenarios} from "./SIMDTESTHook.t.sol";

/// @notice Run with forge test --match-contract MainnetForkTest --fork-url <RPC> --fork-block-number <block>.
/// @dev No environment access or implicit network. Offline tests report an explicit skip.
contract MainnetForkTest is HookScenarios {
    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true, "Supply a mainnet fork via forge --fork-url to rehearse against deployed contracts");
            return;
        }
        _setup(true, false, true);
    }
}
