// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";

// Deployed
//   mint(4) -> init -> Divested
//   init -> Divested
// Divested
//   invest -> Invested
//   mintDivested
//   burnDivested
// Invested
//   divest -> Divested
//   eject -> DivestedAndEjected
//   mint(3)
//   burn
// DivestedAndEjected
//   same as Divested
// DivestedAndEjectedAfterMaturityOfEjected
//   same as DivestedAndEjected
//   redeemEjected -> Divested
// InvestedAndEjected
//   same as Invested
// InvestedAndEjectedAfterMaturityOfEjected
//   same as InvestedAndEjected
//   redeemEjected -> Invested