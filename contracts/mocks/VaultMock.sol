// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;
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
}

interface ICauldron {
    function assets(bytes6) external view returns (address);
    // function series(bytes6) external view returns (DataTypes.Series memory);
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
    IERC20 public immutable base;
    BaseMock private immutable base_;
    address public immutable baseJoin;  // = address(this)
    bytes6 public immutable baseId;      // = bytes6(1)

    mapping (bytes6 => DataTypes.Series) public series;
    mapping (bytes12 => DataTypes.Vault) public vaults;
    mapping (bytes12 => DataTypes.Balances) public balances;

    uint96 public lastVaultId;
    uint48 public nextSeriesId;

    constructor() {
        cauldron = ICauldron(address(this));
        BaseMock base__ = new BaseMock();
        base_ = base__;
        base = IERC20(address(base__));
        baseJoin = address(this);
        baseId = bytes6(uint48(1));
    }

    function assets(bytes6) external view override returns (address) { return address(base); }
    function joins(bytes6) external view override returns (address) { return baseJoin; }

    function addSeries() external returns (bytes6) {
        IFYToken fyToken = IFYToken(address(new FYTokenMock(base_, 0)));
        series[bytes6(nextSeriesId++)] = DataTypes.Series({
            fyToken: fyToken,
            maturity: 0,
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
        if (ink > 0) base_.burn(address(this), uint128(ink)); // Simulate taking the base, which is also the collateral
        if (ink < 0) base_.mint(to, uint128(-ink));
        balances[vaultId].ink.add(ink);
        balances[vaultId].art.add(art);
        address fyToken = address(series[vaults[vaultId].seriesId].fyToken);
        if (art > 0) FYTokenMock(fyToken).mint(to, uint128(art));
        if (ink < 0) FYTokenMock(fyToken).burn(fyToken, uint128(-art));
    }
}
