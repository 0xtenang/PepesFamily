// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PepesFamilyV6} from "../src/PepesFamilyV6.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {PepesFamilyQuoter} from "../src/PepesFamilyQuoter.sol";
import {PadTokenFactory} from "../src/PadTokenFactory.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {Chains} from "../script/Chains.sol";
import {IV4Quoter, IERC20} from "./Fork.t.sol";

/// @notice Launchpad v6 on Elysium mainnet, deployed on a fork exactly as the deploy page sends it (the CREATE2 factory,
///         the init code and salt of script/V6DeployData.s.sol): the real PoolManager and WHYPE, our quoter. Launch,
///         buy and sell with HYPE, the quoter, the four fee shares. Skipped without FORK_RPC_ELYSIUM.
///   FORK_RPC_ELYSIUM=https://rpc.elysium.kinetiq.xyz forge test --mc ElysiumV6ForkTest -vv
contract ElysiumV6ForkTest is Test {
    address constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function _deploy(bytes32 salt, bytes memory init) internal returns (address a) {
        (bool ok, bytes memory ret) = CREATE2.call(abi.encodePacked(salt, init));
        require(ok && ret.length == 20, "create2");
        a = address(bytes20(ret));
    }

    function test_elysiumV6() public {
        string memory rpc = vm.envOr("FORK_RPC_ELYSIUM", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        Chains.Pad memory p = Chains.pad("elysium-whype");
        assertEq(block.chainid, 99901, "Elysium mainnet");

        // the three deploy-page steps, in order
        address quoter = _deploy(0, abi.encodePacked(type(PepesFamilyQuoter).creationCode, abi.encode(p.poolManager)));
        assertEq(quoter, p.quoter, "quoter at its fixed address");
        address factory = _deploy(0, type(PadTokenFactory).creationCode);
        bytes memory init = abi.encodePacked(
            type(PepesFamilyV6).creationCode,
            abi.encode(p.poolManager, p.quote, Chains.OWNER, Chains.OWNER, Chains.OWNER,
                DeployLib.startTickForMarketCap(p.startMcap), p.ethPool, factory)
        );
        (bytes32 salt,) = DeployLib.mineSalt(CREATE2, uint160(0x28CC), init, 0);
        PepesFamilyV6 pad = PepesFamilyV6(payable(_deploy(salt, init)));
        console.log("pad", address(pad), "factory", factory);
        console.log("router", pad.router(), "ethRouter", pad.ethRouter());
        console.log("lens", pad.lens());
        PepesFamilyRouter router = PepesFamilyRouter(payable(pad.router()));
        PepesFamilyEthRouter eth = PepesFamilyEthRouter(payable(pad.ethRouter()));
        IERC20 w = IERC20(p.quote);

        // bob launches with a 1 HYPE first buy (WHYPE through the router)
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.startPrank(bob);
        (bool ok,) = p.quote.call{value: 10 ether}("");
        require(ok, "wrap");
        w.approve(address(router), type(uint256).max);
        (address token, uint256 first) = router.launch("Elysium Pepe", "EPEPE", "{}", p.quote, 1 ether, 1);
        vm.stopPrank();
        PadToken t = PadToken(payable(token));
        assertEq(t.balanceOf(bob), first);

        // the quoter predicts a buy exactly
        PoolKey memory k = pad.poolKey(token);
        (,,,, bool q0) = pad.launches(token);
        (uint256 quoted,) = IV4Quoter(quoter).quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(k, q0, 1 ether, ""));
        vm.prank(bob);
        assertEq(router.buy(token, 1 ether, quoted, block.timestamp), quoted, "quoter matches");

        // carol buys and sells with HYPE itself
        uint256 c0 = carol.balance;
        vm.prank(carol);
        uint256 got = eth.buyWithEth{value: 2 ether}(token, 1, block.timestamp);
        assertEq(c0 - carol.balance, 2 ether);
        vm.startPrank(carol);
        t.approve(address(eth), got);
        uint256 back = eth.sellForEth(token, got, 1, block.timestamp);
        vm.stopPrank();
        assertGt(back, 1.8 ether, "4% each way");
        console.log("2 HYPE in, back (wei):", back);

        // holders earn; protocol 1% and the NFT 1% both reach the team address; the creator's 1% too
        assertGt(t.withdrawableDividendOf(bob), 0, "holders earn");
        uint256 f0 = w.balanceOf(Chains.OWNER);
        pad.collectProtocolFees(p.quote);
        assertGt(w.balanceOf(Chains.OWNER), f0, "protocol + NFT shares collected");
        uint256 b0 = bob.balance;
        pad.collectCreatorFees(token);
        assertGt(bob.balance, b0, "creator paid in HYPE");
    }
}
