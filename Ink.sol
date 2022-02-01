// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./owner/Operator.sol";

contract Ink is ERC20Burnable, Operator {
    using SafeMath for uint256;

    uint256 public FARMING_POOL_REWARD_ALLOCATION = 0 ether;
    uint256 public INVESTMENT_FUND_POOL_ALLOCATION = 0 ether;
    uint256 public DEV_FUND_POOL_ALLOCATION = 0 ether;
    uint256 public VESTING_DURATION = 365 days;

    uint256 public startTime;
    uint256 public endTime;

    uint256 public investmentFundRewardRate;
    uint256 public devFundRewardRate;

    address public investmentFund;
    address public devFund;
    address public buybackFund;
    address public liquidityFund;

    uint256 public investmentFundLastClaimed;
    uint256 public devFundLastClaimed;

    uint256 public taxRateInvestmentFund = 0;

    mapping(address => bool) public noTaxRecipient;
    mapping(address => bool) public noTaxSender;

    bool public rewardPoolDistributed = false;

    constructor(
        uint256 _startTime, 
        address _investmentFund, 
        address _devFund,
        address _buybackFund,
        address _liquidityFund,
        uint256 farmingPoolRewardAllocation,
        uint256 investmentFundPoolAllocation,
        uint256 devFundPoolAllocation,
        uint256 vestingDuration
    ) ERC20("INK", "INK") {
        _mint(msg.sender, 1 ether); // mint 1 INK for initial pools deployment

        FARMING_POOL_REWARD_ALLOCATION = farmingPoolRewardAllocation;
        INVESTMENT_FUND_POOL_ALLOCATION = investmentFundPoolAllocation;
        DEV_FUND_POOL_ALLOCATION = devFundPoolAllocation;
        VESTING_DURATION = vestingDuration;

        startTime = _startTime;
        endTime = startTime + VESTING_DURATION;

        investmentFundLastClaimed = startTime;
        devFundLastClaimed = startTime;

        investmentFundRewardRate = INVESTMENT_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        devFundRewardRate = DEV_FUND_POOL_ALLOCATION.div(VESTING_DURATION);

        require(_devFund != address(0), "Address cannot be 0");
        devFund = _devFund;

        require(_investmentFund != address(0), "Address cannot be 0");
        investmentFund = _investmentFund;

        require(_buybackFund != address(0), "Address cannot be 0");
        buybackFund = _buybackFund;

        require(_liquidityFund != address(0), "Address cannot be 0");
        liquidityFund = _liquidityFund;
    }

    function setInvestmentFundAddress(address _investmentFund) external onlyOperator {
        require(_investmentFund != address(0), "zero");
        investmentFund = _investmentFund;
    }

    function setDevFundAddress(address _devFund) external onlyOperator {
        require(_devFund != address(0), "zero");
        devFund = _devFund;
    }

    function setBuybackFundAddress(address _buybackFund) external onlyOperator {
        require(msg.sender == buybackFund, "!dev");
        require(_buybackFund != address(0), "zero");
        buybackFund = _buybackFund;
    }

    function setLiquidityFundAddress(address _liquidityFund) external onlyOperator {
        require(msg.sender == liquidityFund, "!dev");
        require(_liquidityFund != address(0), "zero");
        liquidityFund = _liquidityFund;
    }

    function setTaxRate(uint256 _taxRate) external onlyOperator {
        taxRateInvestmentFund = _taxRate;
    }

    function unclaimedInvestmentFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (investmentFundLastClaimed >= _now) return 0;
        _pending = _now.sub(investmentFundLastClaimed).mul(investmentFundRewardRate);
    }

    function unclaimedDevFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (devFundLastClaimed >= _now) return 0;
        _pending = _now.sub(devFundLastClaimed).mul(devFundRewardRate);
    }

    /**
     * @dev Claim pending rewards to INVESTMENT and DEV fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedInvestmentFund();
        if (_pending > 0 && investmentFund != address(0)) {
            _mint(investmentFund, _pending);
            investmentFundLastClaimed = block.timestamp;
        }
        _pending = unclaimedDevFund();
        if (_pending > 0 && devFund != address(0)) {
            _mint(devFund, _pending);
            devFundLastClaimed = block.timestamp;
        }
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }

   function setNoTaxSenderAddr(address _noTaxSenderAddr, bool _value) external onlyOperator {
        noTaxSender[_noTaxSenderAddr] = _value;
    }

    function setNoTaxRecipientAddr(address _noTaxRecipientAddr, bool _value) external onlyOperator {
        noTaxRecipient[_noTaxRecipientAddr] = _value;
    }

    function setNoTax(address _noTaxAddr, bool _value) external onlyOperator {
        noTaxSender[_noTaxAddr] = _value;
        noTaxRecipient[_noTaxAddr] = _value;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        uint256 taxAmountInvestment = amount.mul(taxRateInvestmentFund).div(100);
        if (sender == operator() || noTaxRecipient[recipient] || noTaxSender[sender] || taxRateInvestmentFund == 0) {
            super._transfer(sender, recipient, amount);  // transfer with no Tax          
        } else {
            uint256 sendAmount = amount.sub(taxAmountInvestment);
            require(amount == sendAmount + taxAmountInvestment, "Ink: Tax value invalid");

            super._transfer(sender, investmentFund, taxAmountInvestment);
            super._transfer(sender, recipient, sendAmount);
        }
    }
}
