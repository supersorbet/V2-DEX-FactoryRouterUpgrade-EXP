// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.19;

import "../libraries/utils/math/Math.sol";
import "../libraries/utils/math/UQ112x112.sol";
import "../libraries/security/ReentrancyGuard.sol";
import "../libraries/token/ERC20/ERC20WithPermit.sol";
import "../libraries/token/ERC20/utils/TransferHelper.sol";
import "../libraries/token/ERC20/utils/MetadataHelper.sol";

import "../interfaces/ERC20/IERC20.sol";
import "../interfaces/protocol/core/IPair.sol";
import "../interfaces/protocol/core/IFactory.sol";
import "../interfaces/protocol/core/uniswap/IUniswapV2Callee.sol";

//🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐
//🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐
//🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐

contract Pair is
    IPair,
    ERC20WithPermit,
    ReentrancyGuard //pears 🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐🍐
{
    using TransferHelper for address;
    using UQ112x112 for uint224;

    /// liquidity locked 4evr on first initialization of pair
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    uint256 private constant SWAP_FEE_POINT_PRECISION = 10000;
    uint256 private constant SWAP_FEE_POINT_PRECISION_SQ = 10000_0000;

    address public override factory;
    address public override token0;
    address public override token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint256 public override price0CumulativeLast;
    uint256 public override price1CumulativeLast;
    uint256 public override kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint16 private constant SWAP_FEE_INHERIT = type(uint16).max;
    uint16 public override swapFeeOverride = SWAP_FEE_INHERIT;

    // track account balances, uses single storage slot
    struct LiquidityTrackRecord {
        uint112 liquidityTrackRecord0;
        uint112 liquidityTrackRecord1;
        uint32 timeLastUpdate;
    }

    mapping(address => LiquidityTrackRecord) private liquidityTrackRecords;

    ///   create pair
    constructor(address _token0, address _token1) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;

        // try to set symbols for the pair token
        (bool success0, string memory symbol0) = MetadataHelper.getSymbol(_token0);
        (bool success1, string memory symbol1) = MetadataHelper.getSymbol(_token1);
        if (success0 && success1) {
            _initializeMetadata(
                string(abi.encodePacked("V2 ", symbol0, "/", symbol1, " LP Token")),
                string(abi.encodePacked(symbol0, "/", symbol1, " LP"))
            );
        } else {
            _initializeMetadata("LP Token", "LP");
        }
    }

    ///   called by the factory to set the swapFeeOverride
    function setSwapFeeOverride(uint16 _swapFeeOverride) external override {
        require(msg.sender == factory, "FORBIDDEN");
        require(_swapFeeOverride <= 1000 || _swapFeeOverride == SWAP_FEE_INHERIT, "INVALID_FEE");
        swapFeeOverride = _swapFeeOverride;
    }

    /*////////////////////////
        view functions 🤓🤓                 🤓🤓🤓🤓🤓
    //////////////////////////////*/

    function getLiquidityTrackRecord(address account)
        external
        view
        override
        returns (uint112 liquidityTrackRecord0, uint112 liquidityTrackRecord1, uint32 timeLastUpdate)
    {
        LiquidityTrackRecord memory _liquidityTrackRecord = liquidityTrackRecords[account];
        return (
            _liquidityTrackRecord.liquidityTrackRecord0,
            _liquidityTrackRecord.liquidityTrackRecord1,
            _liquidityTrackRecord.timeLastUpdate
        );
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (amount == 0) {
            return;
        }

        // track account balances.
        (uint256 _reserve0, uint256 _reserve1) = _getReserves();
        uint256 _totalSupply = totalSupply();

        if (from != address(0)) {
            uint256 liquidity = balanceOf(from);

            liquidityTrackRecords[from] = LiquidityTrackRecord({
                liquidityTrackRecord0: uint112((liquidity * _reserve0) / _totalSupply),
                liquidityTrackRecord1: uint112((liquidity * _reserve1) / _totalSupply),
                timeLastUpdate: uint32(block.timestamp)
            });
        }
        if (to != address(0)) {
            uint256 liquidity = balanceOf(to);

            liquidityTrackRecords[to] = LiquidityTrackRecord({
                liquidityTrackRecord0: uint112((liquidity * _reserve0) / _totalSupply),
                liquidityTrackRecord1: uint112((liquidity * _reserve1) / _totalSupply),
                timeLastUpdate: uint32(block.timestamp)
            });
        }
    }

    function getReserves()
        external
        view
        override
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function getReservesSimple() external view override returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function getSwapFee() public view override returns (uint16) {
        uint16 _swapFeeOverride = swapFeeOverride;
        return _swapFeeOverride == SWAP_FEE_INHERIT ? IFactory(factory).swapFee() : _swapFeeOverride;
    }

    function getReservesAndParameters()
        external
        view
        override
        returns (uint112 _reserve0, uint112 _reserve1, uint16 _swapFee)
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _swapFee = getSwapFee();
    }

    /*//////////////////////////
        internal functioooooonoooooooooooooons
    //////////////////////////////*/

    function _getReserves() private view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function _getBalances(address _token0, address _token1) private view returns (uint256, uint256) {
        return (IERC20(_token0).balanceOf(address(this)), IERC20(_token1).balanceOf(address(this)));
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "OVERFLOW");

        uint32 blockTimestamp = uint32(block.timestamp);
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                // * never overflows, and + overflow is desired
                price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(reserve0, reserve1);
    }

    function _getFeeLiquidity(uint256 _totalSupply, uint256 _rootK2, uint256 _rootK1, uint8 _feeFactor)
        private
        pure
        returns (uint256)
    {
        uint256 numerator = _totalSupply * (_rootK2 - _rootK1);
        uint256 denominator = (_feeFactor - 1) * _rootK2 + _rootK1;
        return numerator / denominator;
    }

    function _mintProtocolFees(uint112 _reserve0, uint112 _reserve1) private {
        uint256 _kLast = kLast;
        if (_kLast != 0) {
            IFactory _factory = IFactory(factory);
            address _feeTo = _factory.feeTo();

            if (_feeTo != address(0)) {
                uint256 rootK = Math.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = Math.sqrt(_kLast);
                uint256 liquidity = _getFeeLiquidity(totalSupply(), rootK, rootKLast, _factory.protocolFeeFactor());

                if (liquidity > 0) {
                    _mint(_feeTo, liquidity);
                }
            }
        }
    }

    ///   this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external override nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1) = _getReserves();
        (uint256 balance0, uint256 balance1) = _getBalances(token0, token1);
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        _mintProtocolFees(_reserve0, _reserve1);

        {
            uint256 _totalSupply = totalSupply(); // must be defined here since totalSupply can update in `_mintProtocolFees`

            if (_totalSupply == 0) {
                liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
                _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
            } else {
                liquidity = Math.min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
            }

            require(liquidity != 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        }

        _mint(to, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);
        kLast = uint256(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date

        emit Mint(msg.sender, amount0, amount1);
    }

    /*////////////////////////////
        Burn hot hot hot
    ///////////////////////////////*/

    ///   this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1) = _getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        _mintProtocolFees(_reserve0, _reserve1);

        {
            uint256 _totalSupply = totalSupply(); // must be defined here since totalSupply can update in `_mintProtocolFees`

            // using balances ensures pro-rata distribution
            amount0 = (liquidity * balance0) / _totalSupply;
            amount1 = (liquidity * balance1) / _totalSupply;

            require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        }

        _burn(address(this), liquidity);
        _token0.safeTransfer(to, amount0);
        _token1.safeTransfer(to, amount1);

        (balance0, balance1) = _getBalances(_token0, _token1);
        _update(balance0, balance1, _reserve0, _reserve1);

        kLast = uint256(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date

        emit Burn(msg.sender, amount0, amount1, to);
    }

    /*////////////////////
        SWAP 
    /////////////////////////*/

    ///   this low-level function should be called from a contract which performs important safety checks
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)
        external
        override
        nonReentrant
    {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1) = _getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "INSUFFICIENT_LIQUIDITY");

        uint256 balance0After;
        uint256 balance1After;
        {
            (address _token0, address _token1) = (token0, token1);

            if (amount0Out > 0) {
                _token0.safeTransfer(to, amount0Out);
            }
            if (amount1Out > 0) {
                _token1.safeTransfer(to, amount1Out);
            }
            if (data.length > 0) {
                IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            }

            (balance0After, balance1After) = _getBalances(_token0, _token1);
        }

        // one input is required.
        uint256 amount0In = balance0After > _reserve0 - amount0Out ? balance0After - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1After > _reserve1 - amount1Out ? balance1After - (_reserve1 - amount1Out) : 0;
        require(amount0In != 0 || amount1In != 0, "INSUFFICIENT_INPUT_AMOUNT");

        {
            // Checks the K.()
            uint16 _swapFee = getSwapFee();
            uint256 balance0Adjusted = (balance0After * SWAP_FEE_POINT_PRECISION) - (amount0In * _swapFee);
            uint256 balance1Adjusted = (balance1After * SWAP_FEE_POINT_PRECISION) - (amount1In * _swapFee);

            require(
                balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * _reserve1 * (SWAP_FEE_POINT_PRECISION_SQ),
                "K"
            );
        }

        _update(balance0After, balance1After, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function swapFor0(uint256 amount0Out, address to) external override nonReentrant {
        require(amount0Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1) = _getReserves();
        require(amount0Out < _reserve0, "INSUFFICIENT_LIQUIDITY");

        address _token0 = token0;
        _token0.safeTransfer(to, amount0Out);
        (uint256 balance0After, uint256 balance1After) = _getBalances(_token0, token1);

        uint256 amount1In = balance1After - _reserve1;
        require(amount1In != 0, "INSUFFICIENT_INPUT_AMOUNT");

        // Checks the K. Ok...
        uint256 balance1Adjusted = (balance1After * SWAP_FEE_POINT_PRECISION) - (amount1In * getSwapFee());
        require(balance0After * balance1Adjusted >= uint256(_reserve0) * _reserve1 * SWAP_FEE_POINT_PRECISION, "K");

        _update(balance0After, balance1After, _reserve0, _reserve1);
        emit Swap(msg.sender, 0, amount1In, amount0Out, 0, to);
    }

    function swapFor1(uint256 amount1Out, address to) external override nonReentrant {
        require(amount1Out != 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1) = _getReserves();
        require(amount1Out < _reserve1, "INSUFFICIENT_LIQUIDITY");

        address _token1 = token1;
        _token1.safeTransfer(to, amount1Out);
        (uint256 balance0After, uint256 balance1After) = _getBalances(token0, _token1);

        uint256 amount0In = balance0After - _reserve0;
        require(amount0In != 0, "INSUFFICIENT_INPUT_AMOUNT");

        // Checks the K.
        uint256 balance0Adjusted = (balance0After * SWAP_FEE_POINT_PRECISION) - (amount0In * getSwapFee());
        require(balance0Adjusted * balance1After >= uint256(_reserve0) * _reserve1 * SWAP_FEE_POINT_PRECISION, "K");

        _update(balance0After, balance1After, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, 0, 0, amount1Out, to);
    }
    /**
     *   Force balances to match reserves, taking out positive balances
     */

    function skim(address to) external override nonReentrant {
        address _token0 = token0;
        address _token1 = token1;
        (uint256 balance0, uint256 balance1) = _getBalances(_token0, _token1);
        _token0.safeTransfer(to, balance0 - reserve0);
        _token1.safeTransfer(to, balance1 - reserve1);
    }

    /**
     *   Force reserves to match balances
     */
    function sync() external override nonReentrant {
        (uint256 balance0, uint256 balance1) = _getBalances(token0, token1);
        _update(balance0, balance1, reserve0, reserve1);
    }
}
