// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CreatorFeeRouterV2} from "../src/fees/CreatorFeeRouterV2.sol";
import {LevPool} from "../src/LevPool.sol";
import {IPonsLaunchFactory, IPonsFeeEscrow} from "../src/interfaces/IPons.sol";

/// @notice Pons V2 mainnet addresses on Robinhood Chain (4663), read on 2026-10-29. Check them again before use.
abstract contract PonsMainnet {
    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address internal constant PONS_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
}

/// @notice Deploys CreatorFeeRouterV2 for the platform token, before the token exists. The address it prints is the
///         `creatorFeeRecipient` to put in the Pons launch.
/// @dev Env: POOL (LevPool), TREASURY, OWNER (multisig; it owns the router from deployment).
///      Optional: DISTRIBUTOR (default 0 = burn every bought token), DISTRIBUTE_UNTIL (unix time, required with a
///      DISTRIBUTOR; can never be changed), MIN_POOL_BPS (default 4000), PONS_FACTORY / PONS_ESCROW / PONS_HOOK
///      (default: the mainnet addresses above).
///      forge script script/DeployPonsFeeRouter.s.sol:DeployPonsFeeRouter --rpc-url robinhood --broadcast --account <keystore>
///
///      Launch parameters for PonsV2LaunchFactory.launchToken(params, launchConfigId, pairToken):
///      - Launch from a fresh wallet that Pons has whitelisted (`canLaunch(launcher)` is true) and that never buys.
///      - Use the overload without an exemption list: no snipe-tax exemptions. Pons itself exempts the launcher and
///        the recipient (this router); neither ever buys on the curve.
///      - pairToken = address(0): native ETH. The router only claims native ETH.
///      - params.creatorTaxBps = 500. Fixed at launch, forever: it can never be raised or lowered.
///      - params.creatorFeeRecipient = this router, from creation. Left zero, Pons would pay the launcher instead.
///      - params.buybackEnabled = false. Pons buybacks stay off: the router never turns them on, and with them off
///        the router can sweep its own fees without waiting for the Pons operator.
///      - params.expectedEconomics = factory.previewLaunchEconomics(launchConfigId, address(0)) read just before.
///      Then: OWNER calls router.setToken(token) (checks the launch pays this router; buybacks unlock 24 h later), and
///      the keeper calls harvest() about every 10 minutes. Run CheckPonsLaunch and publish what it prints.
///      Never list the platform token on MemeLev.
contract DeployPonsFeeRouter is Script, PonsMainnet {
    function run() external returns (CreatorFeeRouterV2 router) {
        LevPool pool = LevPool(payable(vm.envAddress("POOL")));
        address treasury = vm.envAddress("TREASURY");
        address owner = vm.envAddress("OWNER");
        address distributor = vm.envOr("DISTRIBUTOR", address(0));
        uint64 distributeUntil = uint64(vm.envOr("DISTRIBUTE_UNTIL", uint256(0)));
        uint16 minPoolBps = uint16(vm.envOr("MIN_POOL_BPS", uint256(4000)));
        IPonsLaunchFactory factory = IPonsLaunchFactory(vm.envOr("PONS_FACTORY", PONS_FACTORY));
        IPonsFeeEscrow escrow = IPonsFeeEscrow(vm.envOr("PONS_ESCROW", PONS_ESCROW));
        address hook = vm.envOr("PONS_HOOK", PONS_HOOK);

        require(address(pool).code.length > 0, "POOL has no code");
        require(address(factory).code.length > 0, "PONS_FACTORY has no code on this chain");
        require(address(escrow).code.length > 0, "PONS_ESCROW has no code on this chain");
        require(hook.code.length > 0, "PONS_HOOK has no code on this chain");
        if (distributor != address(0)) {
            require(distributeUntil > block.timestamp, "DISTRIBUTE_UNTIL must be in the future");
        }

        vm.startBroadcast();
        router = new CreatorFeeRouterV2(
            pool, factory, escrow, hook, minPoolBps, treasury, distributor, distributeUntil, owner
        );
        vm.stopBroadcast();

        console.log("CreatorFeeRouterV2", address(router));
        console.log(">> Set this as creatorFeeRecipient in the Pons launch:", address(router));
        console.log("Split: 80% LevPool donation / 10% buyback / 10% ops. Pool floor (bps):", minPoolBps);
        console.log("Bought tokens go to (until DISTRIBUTE_UNTIL, then 0x...dEaD):", router.sink());
        console.log("DISTRIBUTE_UNTIL:", distributeUntil);
        console.log("Launch with: pairToken = 0 (native ETH), creatorTaxBps = 500, creatorFeeRecipient = router,");
        console.log("             no snipe-tax exemptions, buybackEnabled = false, from a fresh launcher that never buys.");
        console.log("OWNER then: setGuardian, proposeGasConfig (7-day timelock); after launch setToken(token);");
        console.log("            after graduation deploy the pool's price feed and proposeBuybackRoute.");
    }
}

/// @notice Re-reads a launch's snapshotted parameters and checks them against the plan. Read-only.
/// @dev Env: TOKEN, ROUTER. Optional PONS_FACTORY.
///      forge script script/DeployPonsFeeRouter.s.sol:CheckPonsLaunch --rpc-url robinhood
contract CheckPonsLaunch is Script, PonsMainnet {
    function run() external view {
        address token = vm.envAddress("TOKEN");
        CreatorFeeRouterV2 router = CreatorFeeRouterV2(payable(vm.envAddress("ROUTER")));
        IPonsLaunchFactory factory = IPonsLaunchFactory(vm.envOr("PONS_FACTORY", PONS_FACTORY));
        IPonsLaunchFactory.LaunchedToken memory lt = factory.getLaunchedToken(token);

        require(lt.exists, "not a Pons launch");
        require(lt.creatorFeeRecipient == address(router), "creator fees do not go to the router");
        require(lt.creatorTaxBps == 500, "creatorTaxBps is not 500");
        require(!lt.buybackEnabled, "Pons buyback is on");
        require(lt.pairToken == address(0), "pair is not native ETH");

        console.log("token", lt.token);
        console.log("curve", lt.curve);
        console.log("launcher", lt.deployer);
        console.log("creatorFeeRecipient", lt.creatorFeeRecipient);
        console.log("creatorTaxBps", lt.creatorTaxBps);
        console.log("graduationThreshold (wei)", lt.graduationThreshold);
        console.log("poolFee", lt.poolFee);
        console.logInt(lt.tickSpacing);
        console.log("phase (0 curve, 1 swept, 2 pool created, 3 rescued)", uint256(lt.phase));
        console.log("graduated pool id:");
        console.logBytes32(router.ponsPoolId(token, lt.pairToken, lt.poolFee, lt.tickSpacing));
        console.log("router token set:", router.token() == token);
    }
}
