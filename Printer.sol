// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";

contract ShareWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public ink;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        ink.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        uint256 printerShare = _balances[msg.sender];
        require(printerShare >= amount, "Printer: withdraw request greater than staked amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = printerShare.sub(amount);
        ink.safeTransfer(msg.sender, amount);
    }
}

contract Printer is ShareWrapper, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Printerseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct PrinterSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    IERC20 public paper;
    ITreasury public treasury;

    mapping(address => Printerseat) public printers;
    PrinterSnapshot[] public printerHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Printer: caller is not the operator");
        _;
    }

    modifier printerExists {
        require(balanceOf(msg.sender) > 0, "Printer: The printer does not exist");
        _;
    }

    modifier updateReward(address printer) {
        if (printer != address(0)) {
            Printerseat memory seat = printers[printer];
            seat.rewardEarned = earned(printer);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            printers[printer] = seat;
        }
        _;
    }

    modifier notInitialized {
        require(!initialized, "Printer: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _paper,
        IERC20 _ink,
        ITreasury _treasury
    ) public notInitialized {
        paper = _paper;
        ink = _ink;
        treasury = _treasury;

        PrinterSnapshot memory genesisSnapshot = PrinterSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        printerHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 6; // Lock for 6 epochs (36h) before release withdraw
        rewardLockupEpochs = 3; // Lock for 3 epochs (18h) before release claimReward

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return printerHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (PrinterSnapshot memory) {
        return printerHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address printer) public view returns (uint256) {
        return printers[printer].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address printer) internal view returns (PrinterSnapshot memory) {
        return printerHistory[getLastSnapshotIndexOf(printer)];
    }

    function canWithdraw(address printer) external view returns (bool) {
        return printers[printer].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address printer) external view returns (bool) {
        return printers[printer].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    // =========== Printer getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address printer) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(printer).rewardPerShare;

        return balanceOf(printer).mul(latestRPS.sub(storedRPS)).div(1e18).add(printers[printer].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Printer: Cannot stake 0");
        super.stake(amount);
        printers[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override onlyOneBlock printerExists updateReward(msg.sender) {
        require(amount > 0, "Printer: Cannot withdraw 0");
        require(printers[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Printer: still in withdraw lockup");
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = printers[msg.sender].rewardEarned;
        if (reward > 0) {
            require(printers[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Printer: still in reward lockup");
            printers[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            printers[msg.sender].rewardEarned = 0;
            paper.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyOperator {
        require(amount > 0, "Printer: Cannot allocate 0");
        require(totalSupply() > 0, "Printer: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        PrinterSnapshot memory newSnapshot = PrinterSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        printerHistory.push(newSnapshot);

        paper.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(paper), "paper");
        require(address(_token) != address(ink), "ink");
        _token.safeTransfer(_to, _amount);
    }
}
