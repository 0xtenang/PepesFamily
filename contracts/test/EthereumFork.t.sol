// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter, FeeSplit} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {PepesFamilyLens} from "../src/PepesFamilyLens.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {Chains} from "../script/Chains.sol";
import {IV4Quoter, IERC20} from "./Fork.t.sol";

/// @notice PepesFamily v5 on an Ethereum mainnet fork, with the settings the Ethereum deployment uses (script/Chains.sol):
///         the real PoolManager, IMD (IMD's home chain), the ETH/IMD v4 pool and Uniswap's V4Quoter.
///   FORK_RPC_ETH=https://ethereum-rpc.publicnode.com forge test --mc EthereumForkTest -vv
contract EthereumForkTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Chains.Config c;
    PepesFamily pad;
    PepesFamilyRouter router;
    PepesFamilyEthRouter eth;
    PepesFamilyLens lens;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_ETH", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        c = Chains.get(1);
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(c.poolManager, c.imd, Chains.OWNER, Chains.OWNER, DeployLib.startTickForMarketCap(635e18), c.imdEthPool)
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));
        eth = PepesFamilyEthRouter(payable(pad.ethRouter()));
        lens = PepesFamilyLens(pad.lens());
        address[2] memory users = [bob, carol];
        for (uint256 i; i < users.length; i++) {
            vm.deal(users[i], 10 ether);
            // borrow IMD from the PoolManager's balance (it holds the ETH/IMD pool's IMD)
            vm.prank(address(c.poolManager));
            IERC20(c.imd).transfer(users[i], 1_000e18);
            vm.prank(users[i]);
            IERC20(c.imd).approve(address(router), type(uint256).max);
        }
    }

    function test_eth_launchSplitTradeAndQuote() public {
        vm.prank(bob);
        (address token, uint256 out) = router.launchWithSplit("Eth Frog", "EFROG", "{}", c.imd, FeeSplit(100, 100, 100), 50e18, 1);
        PadToken t = PadToken(payable(token));
        assertEq(t.balanceOf(bob), out);
        (, address creator, uint64 createdAt, uint64 createdBlock,) = pad.launches(token);
        assertEq(creator, bob);
        assertEq(createdAt, block.timestamp);
        assertEq(createdBlock, block.number, "no ArbSys on Ethereum: falls back to block.number");
        console.log("start market cap after a 50 IMD buy (IMD wei)", lens.marketCap(token));

        // Uniswap's V4Quoter predicts what the router delivers, fee and burn included
        PoolKey memory key = pad.poolKey(token);
        (,,,, bool quoteIs0) = pad.launches(token);
        (uint256 quoted,) = IV4Quoter(c.quoter).quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, quoteIs0, 100e18, ""));
        uint256 dead0 = t.balanceOf(DEAD);
        uint256 creator0 = pad.pendingCreatorFees(token);
        vm.prank(carol);
        assertEq(router.buy(token, 100e18, quoted, block.timestamp), quoted);
        assertGt(t.balanceOf(DEAD), dead0, "burn share burned");
        assertEq(pad.pendingCreatorFees(token) - creator0, 1e18, "1% of 100 IMD to the creator");
        assertGt(t.withdrawableDividendOf(bob), 0, "holders earn their 1%");

        // holders claim, the creator collects, protocol fees go to the fee address
        uint256 b0 = IERC20(c.imd).balanceOf(bob);
        vm.prank(bob);
        t.claim();
        pad.collectCreatorFees(token);
        assertGt(IERC20(c.imd).balanceOf(bob), b0);
        uint256 f0 = IERC20(c.imd).balanceOf(Chains.OWNER);
        pad.collectProtocolFees(c.imd);
        assertGt(IERC20(c.imd).balanceOf(Chains.OWNER), f0);

        // sell everything back
        uint256 bal = t.balanceOf(carol);
        vm.startPrank(carol);
        t.approve(address(router), bal);
        assertGt(router.sell(token, bal, 1, block.timestamp), 0);
        vm.stopPrank();
    }

    /// The ETH router trades through Ethereum's deep ETH/IMD pool (1% fee, tick spacing 200).
    function test_eth_buyAndSellWithEth() public {
        vm.prank(bob);
        (address token,) = router.launchWithSplit("Eth Pepe", "EPEPE", "{}", c.imd, FeeSplit(0, 300, 0), 20e18, 1);
        PadToken t = PadToken(payable(token));
        uint256 ethBefore = carol.balance;
        vm.prank(carol);
        uint256 got = eth.buyWithEth{value: 0.1 ether}(token, 1, block.timestamp);
        assertGt(got, 0);
        assertEq(t.balanceOf(carol), got);
        assertEq(ethBefore - carol.balance, 0.1 ether);
        assertEq(t.lastActive(carol), block.timestamp, "the ETH router credits the buyer");
        vm.startPrank(carol);
        t.approve(address(eth), got);
        uint256 back = eth.sellForEth(token, got, 1, block.timestamp);
        vm.stopPrank();
        assertGt(back, 0.08 ether, "round trip through two 1% pools and the 4% hook");
        assertLt(back, 0.1 ether);
    }

    /// Holder rewards still expire after 7 days of inactivity and go to the fee address.
    function test_eth_expiry() public {
        vm.prank(bob);
        (address token,) = router.launchWithSplit("Eth Exp", "EEXP", "{}", c.imd, FeeSplit(0, 300, 0), 20e18, 1);
        PadToken t = PadToken(payable(token));
        vm.prank(carol);
        router.buy(token, 100e18, 1, block.timestamp);
        uint256 owed = t.withdrawableDividendOf(bob);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 f0 = IERC20(c.imd).balanceOf(Chains.OWNER);
        assertEq(t.recycle(bob), owed);
        assertEq(IERC20(c.imd).balanceOf(Chains.OWNER) - f0, owed);
    }
}
