// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";

contract SIMDTESTTest is Test {
    SIMDTEST internal token;

    function setUp() public {
        token = new SIMDTEST();
    }

    function test_FactoryReceivesEntirePolicySupply() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
    }

    function testFuzz_TransferAndAllowanceConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        address recipient = makeAddr("recipient");
        address spender = makeAddr("spender");
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1);
    }

    function test_NoMintOwnerUpgradeOrPauseEntrypoints() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), 1e27));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
