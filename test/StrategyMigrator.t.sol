// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/Strategy.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/vault-v2/src/interfaces/IFYToken.sol";
import { TestConstants } from "./utils/TestConstants.sol";
import { ERC1967Proxy } from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract ZeroState is Test, TestConstants {

    // Strategies
    // 0x1030FF000000 0xad1983745D6c739537fEaB5bed45795f47A940b3
    // 0x1030FF000001 0x5582b8398FB586F1b79edd1a6e83f1c5aa558955
    // 0x1031FF000000 0x4276BEaA49DE905eED06FCDc0aD438a19D3861DD
    // 0x1031FF000001 0x5aeB4EFaAA0d27bd606D618BD74Fe883062eAfd0
    // 0x1032FF000000 0x33e6B154efC7021dD55464c4e11a6AfE1f3D0635
    // 0x1032FF000001 0x3b4FFD93CE5fCf97e61AA8275Ec241C76cC01a47
    // 0x10A0FF000000 0x861509A3fA7d87FaA0154AAE2CB6C1f92639339A
    // 0x10A0FF000001 0xfe2Aba5ba890AF0ee8B6F2d488B1f85C9E7C5643

    // FYToken
    // 0x0030FF00028B 0x523803c57a497c3AD0E850766c8276D4864edEA5
    // 0x0031FF00028B 0x60a6A7fabe11ff36cbE917a17666848f0FF3A60a
    // 0x0032FF00028B 0xCbB7Eba13F9E1d97B2138F588f5CA2F5167F06cc
    // 0x00A0FF000288 0xC24DA474A71C44d2b644089020ba255908AdA6e1
    // 0x00A0FF00028B 0x035072cb2912DAaB7B578F468Bd6F0d32a269E32
    // 0x0030FF00028E 0xd947360575E6F01Ce7A210C12F2EE37F5ab12d11
    // 0x0031FF00028E 0xEE508c827a8990c04798B242fa801C5351012B23
    // 0x0032FF00028E 0x5Bb78E530D9365aeF75664c5093e40B0001F7CCd
    // 0x00A0FF00028E 0x9B19889794A30056A1E5Be118ee0a6647B184c5f

    address timelock = 0xd0a22827Aed2eF5198EbEc0093EA33A4CD641b6c;
    // We will warp to the December to June roll, and migrate the MJD strategy to a contract impersonating the March series.
    Strategy srcStrategy = Strategy(0xad1983745D6c739537fEaB5bed45795f47A940b3);
    IFYToken fyToken = IFYToken(0x523803c57a497c3AD0E850766c8276D4864edEA5); // Needs to match the base of the srcStrategy and dstStrategy
    Strategy dstStrategy;
    IERC20 baseToken;

    address srcStrategyHolder = 0x3353E1E2976DBbc191a739871faA8E6E9D2622c7;

    function setUp() public virtual {
        vm.createSelectFork("MIGRATE_TESTS"); // Will only work on https://rpc.tenderly.co/fork/b9c353b6-37ae-4f9c-8649-5d23df9f862f

        baseToken = srcStrategy.base();

        dstStrategy = new Strategy("", "", baseToken);

        ERC1967Proxy dstStrategyProxy = new ERC1967Proxy(
            address(dstStrategy),
            abi.encodeWithSignature(
                "initialize(address,address)",
                address(this),
                address(fyToken)
            )
        );
        dstStrategy = Strategy(address(dstStrategyProxy));

        dstStrategy.grantRole(StrategyMigrator.init.selector, address(srcStrategy));

        vm.label(address(srcStrategy), "srcStrategy");
        vm.label(address(dstStrategy), "dstStrategy");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(fyToken), "fyToken");
    }
}

contract ZeroStateTest is ZeroState {
    function testInvestToMigrate() public {
        console2.log("srcStrategy.invest()");
        uint256 migratedBase = baseToken.balanceOf(address(srcStrategy));

        vm.prank(timelock);
        srcStrategy.invest(IPool(address(dstStrategy)));

        // srcStrategy has no base
        assertEq(baseToken.balanceOf(address(srcStrategy)), 0);
        // dstStrategy has the base
        assertEq(baseToken.balanceOf(address(dstStrategy)), migratedBase);
    }
}

abstract contract MigratedState is ZeroState {
    function setUp() public override virtual {
        super.setUp();
        vm.prank(timelock);
        srcStrategy.invest(IPool(address(dstStrategy)));
    }
}

contract MigratedStateTest is MigratedState {
    function testBurnAfterMigrate() public {
        console2.log("srcStrategy.burn()");
        uint256 srcStrategySupply = srcStrategy.totalSupply();
        uint256 dstStrategySupply = dstStrategy.totalSupply();
        uint256 srcStrategyHolderBalance = srcStrategy.balanceOf(srcStrategyHolder);
        uint256 expectedDstStrategyBalance = (srcStrategyHolderBalance * dstStrategySupply) / srcStrategySupply;
        assertGe(expectedDstStrategyBalance, 0);

        vm.prank(srcStrategyHolder);
        srcStrategy.transfer(address(srcStrategy), srcStrategyHolderBalance);
        srcStrategy.burn(srcStrategyHolder);

        // srcStrategyHolder has no srcStrategy tokens
        assertEq(srcStrategy.balanceOf(address(srcStrategyHolder)), 0);
        // srcStrategyHolder has the same proportion of dstStrategy than he had of srcStrategy
        assertEq(dstStrategy.balanceOf(address(srcStrategyHolder)), expectedDstStrategyBalance);
    }

    function testMintAfterMigrate() public {
        console2.log("srcStrategy.mint()");
        uint256 srcStrategyHolderBalance = srcStrategy.balanceOf(srcStrategyHolder);
        assertGe(srcStrategyHolderBalance, 0);

        // We burn strategy v1 to get strategy v2 tokens
        vm.prank(srcStrategyHolder);
        srcStrategy.transfer(address(srcStrategy), srcStrategyHolderBalance);
        uint256 withdrawal = srcStrategy.burn(srcStrategyHolder);

        // Now we should be able to undo the burn using mint
        vm.prank(srcStrategyHolder);
        dstStrategy.transfer(address(srcStrategy), withdrawal);
        srcStrategy.mint(srcStrategyHolder);

        // srcStrategyHolder has no dstStrategy tokens
        assertEq(dstStrategy.balanceOf(address(srcStrategyHolder)), 0);
        // srcStrategyHolder has the same srcStrategy tokens he had before
        assertEq(srcStrategy.balanceOf(address(srcStrategyHolder)), srcStrategyHolderBalance - 4); // TODO: Do the conversions rounding down to get to this value
    }
}