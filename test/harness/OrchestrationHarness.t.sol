// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import { Strategy, AccessControl } from "../../src/Strategy.sol";
import { ILadle } from "@yield-protocol/vault-v2/src/interfaces/ILadle.sol";
import { TestConstants } from "./../utils/TestConstants.sol";
import { TestExtensions } from "./../utils/TestExtensions.sol";

/// @dev This test harness tests that a deployed and invested strategy is functional.

abstract contract ZeroState is Test, TestConstants, TestExtensions {
    using stdStorage for StdStorage;

    bool ci; // Skip the tests on CI

    address timelock;
    ILadle ladle;

    Strategy strategy;

    modifier skipOnCI() {
        if (ci == true) {
            console2.log("On CI, skipping...");
            return;
        }
        _;
    }

    function setUp() public virtual {
        if (!(ci = vm.envOr(CI, true))) {
            string memory rpc = vm.envOr(RPC, HARNESS);
            vm.createSelectFork(rpc);

            string memory network = vm.envOr(NETWORK, MAINNET);
            timelock = addresses[network][TIMELOCK];
            ladle = ILadle(addresses[network][LADLE]);

            strategy = Strategy(vm.envAddress(STRATEGY));

            vm.label(address(ladle), "ladle");
            vm.label(address(strategy), "strategy");
        }     
    }
}

contract ZeroStateTest is ZeroState {
    function testTimelockHasRoot() public skipOnCI {
        assertTrue(strategy.hasRole(strategy.ROOT(), timelock));
    }
    function testStrategyIsToken() public skipOnCI {
        assertTrue(ladle.tokens(address(strategy)));
    }

    function testStrategyIsIntegration() public skipOnCI {
        assertTrue(ladle.integrations(address(strategy)));
    }
}
