// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter, FeeSplit} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {Chains} from "../script/Chains.sol";
import {IV4Quoter, IERC20} from "./Fork.t.sol";

interface IWrapped {
    function deposit() external payable;
}

/// @notice The launchpads added on 2026-10-18 ($PEPE and WETH on Ethereum), each on a fork of its chain with the settings it deploys with
///         (script/Chains.sol `pad`): the real PoolManager, pair asset and V4Quoter, and the ETH router (through
///         the ETH/asset v4 pool) or the native router (wrapping the chain's coin). Each test is skipped without its RPC.
///   FORK_RPC_ETH=https://ethereum-rpc.publicnode.com forge test --mc NewPadsForkTest -vv
contract NewPadsForkTest is Test {
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function test_ethereumPepe() public { _run("ethereum-pepe", "FORK_RPC_ETH"); }
    function test_ethereumWeth() public { _run("ethereum-weth", "FORK_RPC_ETH"); }

    function _run(string memory key, string memory rpcEnv) internal {
        string memory rpc = vm.envOr(rpcEnv, string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        Chains.Pad memory p = Chains.pad(key);
        assertEq(block.chainid, p.chainId, "right chain");
        bool wrapped = p.ethPool.tickSpacing == 0;

        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(p.poolManager, p.quote, Chains.OWNER, Chains.OWNER, DeployLib.startTickForMarketCap(p.startMcap), p.ethPool)
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly { deployed := create2(0, add(initCode, 0x20), mload(initCode), salt) }
        require(deployed != address(0), "deploy");
        PepesFamily pad = PepesFamily(deployed);
        PepesFamilyRouter router = PepesFamilyRouter(payable(pad.router()));
        PepesFamilyEthRouter eth = PepesFamilyEthRouter(payable(pad.ethRouter())); // same functions either way
        IERC20 q = IERC20(p.quote);

        // pair-asset money for bob (the launcher) and carol
        uint256 unit = p.startMcap / 100; // 1% of the starting market cap
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? bob : carol;
            vm.deal(u, 100 ether);
            if (wrapped) { vm.prank(u); IWrapped(p.quote).deposit{value: 20 ether}(); }
            else deal(p.quote, u, unit * 50);
            vm.prank(u);
            q.approve(address(router), type(uint256).max);
        }

        // launch with a first buy, split 1% creator / 1% holders / 1% burn
        vm.prank(bob);
        (address token, uint256 first) = router.launchWithSplit("New Pad", "NEWP", "{}", p.quote, FeeSplit(100, 100, 100), unit, 1);
        PadToken t = PadToken(payable(token));
        assertEq(t.balanceOf(bob), first);
        (address quote,,,,) = pad.launches(token);
        assertEq(quote, p.quote);

        // Uniswap's V4Quoter predicts the router exactly
        PoolKey memory k = pad.poolKey(token);
        (,,,, bool q0) = pad.launches(token);
        (uint256 quoted,) = IV4Quoter(p.quoter).quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(k, q0, uint128(unit), ""));
        vm.prank(carol);
        assertEq(router.buy(token, unit, quoted, block.timestamp), quoted, "quoter matches");

        // buy and sell with the chain's own coin
        uint256 c0 = carol.balance;
        vm.prank(carol);
        uint256 got = eth.buyWithEth{value: wrapped ? 0.05 ether : 0.01 ether}(token, 1, block.timestamp);
        assertGt(got, 0);
        assertEq(c0 - carol.balance, wrapped ? 0.05 ether : 0.01 ether);
        vm.startPrank(carol);
        t.approve(address(eth), got);
        uint256 back = eth.sellForEth(token, got, 1, block.timestamp);
        vm.stopPrank();
        assertGt(back, 0);
        console.log(key, "native in, native back (wei):", wrapped ? 0.05 ether : 0.01 ether, back);

        // holders earn in the pair asset; the 1% protocol fee reaches the owner
        assertGt(t.withdrawableDividendOf(bob), 0, "holders earn");
        uint256 f0 = q.balanceOf(Chains.OWNER);
        pad.collectProtocolFees(p.quote);
        assertGt(q.balanceOf(Chains.OWNER), f0, "protocol fee collected");
        console.log(key, "pad at", address(pad));
    }
}
