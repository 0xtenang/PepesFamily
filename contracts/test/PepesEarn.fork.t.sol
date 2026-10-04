// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {PepesEarnIMD} from "../src/earn/PepesEarnIMD.sol";
import {PepesEarnToken} from "../src/earn/PepesEarnToken.sol";
import {PepesEarnMirror} from "../src/earn/PepesEarnMirror.sol";
import {PepesEarnRenderer} from "../src/earn/PepesEarnRenderer.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {IERC20} from "./Fork.t.sol";

interface IV1Pad {
    function pendingHolderFees(address token) external view returns (uint256);
}

interface IPepesToken {
    function totalDividendsDistributed() external view returns (uint256);
}

/// @notice Pepes Earn IMD on a Robinhood Chain mainnet fork: real PoolManager, real IMD and IMD/ETH pool, and the
///         real $Pepes token and PepesFamily v1 router for the buyback-and-burn.
///   FORK_RPC=https://robinhood.drpc.org forge test --mc PepesEarnForkTest -vv
contract PepesEarnForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant PEPES = 0xE2C46c7068566740A33A4C93f5445B07BCfE5644;
    address constant V1_PAD = 0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC;
    address constant V1_ROUTER = 0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC;
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PepesEarnIMD hook;
    PepesEarnToken earn;
    PepesEarnMirror mirror;
    PepesFamilyRouter router;
    PepesFamilyEthRouter ethRouter;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        PepesEarnRenderer renderer = new PepesEarnRenderer();
        bytes memory initCode = abi.encodePacked(
            type(PepesEarnIMD).creationCode,
            abi.encode(
                PM,
                IMD,
                address(this),
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(2_000e18, 2_000e18),
                PepesEarnIMD.ImdEthPool(10_000, 100, address(0))
            )
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        hook = PepesEarnIMD(payable(deployed));
        router = PepesFamilyRouter(payable(hook.router()));
        ethRouter = PepesFamilyEthRouter(payable(hook.ethRouter()));
        mirror = new PepesEarnMirror(address(hook));
        earn = new PepesEarnToken(address(hook), address(mirror), address(renderer), PEPES, V1_ROUTER);
        hook.openPool(address(earn));

        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < users.length; i++) {
            vm.deal(users[i], 10 ether);
            vm.prank(address(PM));
            IERC20(IMD).transfer(users[i], 200e18);
            vm.startPrank(users[i]);
            IERC20(IMD).approve(address(router), type(uint256).max);
            earn.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _buy(address who, uint256 imdIn) internal returns (uint256) {
        vm.prank(who);
        return router.buy(address(earn), imdIn, 1, block.timestamp);
    }

    function test_fork_fullLifecycle() public {
        // trade with IMD and with ETH; NFTs follow whole tokens
        uint256 a = _buy(alice, 100e18);
        assertEq(mirror.balanceOf(alice), a / 1e18);
        vm.prank(bob);
        uint256 b = ethRouter.buyWithEth{value: 0.05 ether}(address(earn), 1, block.timestamp);
        assertGt(b, 0);
        assertEq(mirror.balanceOf(bob), b / 1e18);
        uint256 aliceRewards = earn.withdrawableDividendOf(alice);
        assertGt(aliceRewards, 0, "alice earns from bob's trade");

        // metadata renders on the real chain
        string memory uri = mirror.tokenURI(1);
        assertGt(bytes(uri).length, 1000);

        // an NFT sale moves 1 $EARN; carol can sell it to the pool afterwards
        uint256 id = 1;
        address holder = mirror.ownerOf(id);
        vm.prank(holder);
        mirror.transferFrom(holder, carol, id);
        assertEq(earn.balanceOf(carol), 1e18);
        uint256 imdBefore = IERC20(IMD).balanceOf(carol);
        vm.prank(carol);
        router.sell(address(earn), 1e18, 1, block.timestamp);
        assertGt(IERC20(IMD).balanceOf(carol), imdBefore);
        assertEq(mirror.balanceOf(carol), 0);

        // 31 days of inactivity: alice's rewards expire and buy back + burn real $Pepes
        vm.warp(block.timestamp + 31 days);
        uint256 expired = earn.recycle(alice);
        assertGt(expired, 0);
        uint256 deadBefore = IERC20(PEPES).balanceOf(DEAD);
        uint256 pepesHolderFeesBefore =
            IV1Pad(V1_PAD).pendingHolderFees(PEPES) + IPepesToken(PEPES).totalDividendsDistributed();
        uint256 burned = earn.buybackAndBurnPepes(expired, 1, block.timestamp);
        assertGt(burned, 0);
        assertEq(IERC20(PEPES).balanceOf(DEAD) - deadBefore, burned, "bought $Pepes went to the burn address");
        assertEq(IERC20(PEPES).balanceOf(address(earn)), 0);
        assertGt(
            IV1Pad(V1_PAD).pendingHolderFees(PEPES) + IPepesToken(PEPES).totalDividendsDistributed(),
            pepesHolderFeesBefore,
            "the buyback paid $Pepes holders their 3%"
        );
        assertEq(IERC20(IMD).balanceOf(address(earn)), earn.accountedBalance() + earn.buybackReserve());

        // a marketplace royalty in ETH becomes IMD: 1% protocol, 3% holders
        (bool ok,) = address(hook).call{value: 0.02 ether}("");
        assertTrue(ok);
        uint256 feeBefore = IERC20(IMD).balanceOf(FEE_RECIPIENT);
        uint256 distributedBefore = earn.totalDividendsDistributed();
        uint256 out = hook.convertRoyalties(1);
        assertGt(out, 0);
        assertEq(IERC20(IMD).balanceOf(FEE_RECIPIENT) - feeBefore, out / 4);
        assertEq(earn.totalDividendsDistributed() - distributedBefore, out - out / 4);

        // holders claim
        uint256 bobImd = IERC20(IMD).balanceOf(bob);
        vm.prank(bob);
        uint256 paid = earn.claim();
        assertEq(IERC20(IMD).balanceOf(bob) - bobImd, paid);
        emit log_named_uint("expired IMD recycled", expired);
        emit log_named_uint("$Pepes burned", burned);
        emit log_named_uint("royalty IMD", out);
    }
}
