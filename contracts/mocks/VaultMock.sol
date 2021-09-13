// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.6;
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/vault-interfaces/IFYToken.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";
import "./BaseMock.sol";
import "./FYTokenMock.sol";


interface ILadle {
    function joins(bytes6) external view returns (address);
    function cauldron() external view returns (ICauldron);
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external returns (bytes12 vaultId, DataTypes.Vault memory vault);
    function destroy(bytes12 vaultId) external;
    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external;
    function close(bytes12 vaultId, address to, int128 ink, int128 art) external;
}

interface ICauldron {
    function assets(bytes6) external view returns (address);
    function debt(bytes6 baseId, bytes6 ilkId) external view returns (DataTypes.Debt memory);
}

library CauldronMath {
    /// @dev Add a number (which might be negative) to a positive, and revert if the result is negative.
    function add(uint128 x, int128 y) internal pure returns (uint128 z) {
        require (y > 0 || x >= uint128(-y), "Result below zero");
        z = y > 0 ? x + uint128(y) : x - uint128(-y);
    }
}

contract VaultMock is ICauldron, ILadle {
    using CauldronMath for uint128;

    ICauldron public immutable override cauldron;
    BaseMock public immutable base;
    address public immutable baseJoin;  // = address(this)
    bytes6 public immutable baseId;      // = bytes6(1)

    mapping (bytes6 => DataTypes.Series) public series;
    mapping (bytes12 => DataTypes.Vault) public vaults;
    mapping (bytes12 => DataTypes.Balances) public balances;

    uint96 public lastVaultId;
    uint48 public nextSeriesId;

    constructor() {
        cauldron = ICauldron(address(this));
        base = new BaseMock();
        baseJoin = address(this);
        baseId = bytes6(uint48(1));
    }

    function assets(bytes6) external view override returns (address) { return address(base); }

    function joins(bytes6) external view override returns (address) { return baseJoin; }

    function debt(bytes6, bytes6) external pure override returns (DataTypes.Debt memory) {
        return DataTypes.Debt({ max: 1000000, min: 1, dec: 18, sum: 0 });
    }

    function debtToBase(bytes6, uint128 art) external pure returns (uint128) { return art; }

    function addSeries(uint32 maturity_) external returns (bytes6) {
        IFYToken fyToken = IFYToken(address(new FYTokenMock(base, maturity_)));
        series[bytes6(nextSeriesId++)] = DataTypes.Series({
            fyToken: fyToken,
            maturity: maturity_,
            baseId: baseId
        });

        return bytes6(nextSeriesId - 1);
    }

    function build(bytes6 seriesId, bytes6 ilkId, uint8) external override returns (bytes12 vaultId, DataTypes.Vault memory vault) {
        vaults[bytes12(lastVaultId++)] = DataTypes.Vault({
            owner: msg.sender,
            seriesId: seriesId,
            ilkId: ilkId
        });

        return (bytes12(lastVaultId - 1), vaults[bytes12(lastVaultId - 1)]);
    }

    function destroy(bytes12 vaultId) external override {
        require (balances[vaultId].art == 0 && balances[vaultId].ink == 0, "Only empty vaults");
        delete vaults[vaultId];
    }

    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external override {
        if (ink > 0) base.burn(address(this), uint128(ink)); // Simulate taking the base, which is also the collateral
        if (ink < 0) base.mint(to, uint128(-ink));
        balances[vaultId].ink = balances[vaultId].ink.add(ink);
        balances[vaultId].art = balances[vaultId].art.add(art);
        address fyToken = address(series[vaults[vaultId].seriesId].fyToken);
        if (art > 0) FYTokenMock(fyToken).mint(to, uint128(art));
        if (art < 0) FYTokenMock(fyToken).burn(fyToken, uint128(-art));
    }

    function close(bytes12 vaultId, address to, int128 ink, int128 art) external override {
        if (ink > 0) base.burn(address(this), uint128(ink)); // Simulate taking the base, which is also the collateral
        if (ink < 0) base.mint(to, uint128(-ink));
        balances[vaultId].ink = balances[vaultId].ink.add(ink);
        balances[vaultId].art = balances[vaultId].art.add(art);
        if (art > 0) revert ("Only repay debt");
        if (art < 0) base.burn(address(this), uint128(-art)); // We apply a 1:1 base/fyToken rate for this mock
    }
}
