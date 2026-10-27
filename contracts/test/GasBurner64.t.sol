// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter, FeeSplit} from "../src/PepesFamilyRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {MockWETH} from "./NativeRouter.t.sol";

/// @notice What failed on BSC: at 0x64 BSC has a system precompile that errors by burning all the gas it is given.
///         The launchpad reads Arbitrum's block number there; with a fixed gas allowance for that call, a launch and
///         a buy still go through.
contract Burner {
    fallback() external {
        assembly { invalid() } // consumes every unit of gas the call was given, like a failing precompile
    }
}

contract GasBurner64Test is Test {
    function test_launchesWhen0x64BurnsGas() public {
        vm.etch(address(100), address(new Burner()).code);
        PoolManager pm = new PoolManager(address(this));
        MockWETH weth = new MockWETH();
        bytes memory initCode = abi.encodePacked(type(PepesFamily).creationCode,
            abi.encode(pm, address(weth), address(this), address(this), DeployLib.startTickForMarketCap(5e18), PepesFamily.ImdEthPool(0, 0, address(0))));
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly { deployed := create2(0, add(initCode, 0x20), mload(initCode), salt) }
        PepesFamily pad = PepesFamily(deployed);
        PepesFamilyRouter router = PepesFamilyRouter(payable(pad.router()));
        weth.deposit{value: 1 ether}();
        weth.approve(address(router), type(uint256).max);
        // a realistic gas limit for the whole launch-and-buy transaction
        (address token, uint256 got) = router.launchWithSplit{gas: 3_500_000}("Gas", "GAS", "{}", address(weth), FeeSplit(0, 300, 0), 0.05 ether, 1);
        assertGt(got, 0);
        assertEq(PadToken(payable(token)).balanceOf(address(this)), got);
        (,,, uint64 createdBlock,) = pad.launches(token);
        assertEq(createdBlock, block.number, "falls back to block.number");
    }
}
