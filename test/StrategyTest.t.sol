// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";

// Deployed
//   mint(4) -> init -> Divested ✓
//   init -> Divested
// Divested
//   mintDivested
//   burnDivested
//   invest -> Invested
// Invested
//   mint(3)
//   burn
//   eject -> DivestedAndEjected
//   time passes -> InvestedAfterMaturity
// InvestedAfterMaturity
//   divest -> Divested

// DivestedAndEjected
//   same as Divested
//   time passes -> DivestedAndEjectedAfterMaturityOfEjected
// InvestedAndEjected
//   same as Invested
//   time passes -> InvestedAfterMaturityAndEjected
//   time passes -> InvestedAndAfterMaturityOfEjected
//   time passes -> InvestedAfterMaturityAndAfterMaturityOfEjected
// InvestedAfterMaturityAndEjected
//   divest -> DivestedAndEjected
//   time passes -> InvestedAfterMaturityAndAfterMaturityOfEjected

// DivestedAndEjectedAfterMaturityOfEjected
//   same as DivestedAndEjected
//   redeemEjected -> Divested
// InvestedAfterMaturityAndEjected
//   same as InvestedAfterMaturity
// InvestedAndAfterMaturityOfEjected
//   same as Invested
//   redeemEjected -> Invested
// InvestedAfterMaturityAndAfterMaturityOfEjected
//   same as InvestedAfterMaturity
//   redeemEjected -> InvestedAfterMaturity