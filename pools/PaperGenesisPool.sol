// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Note that this pool has no minter key of PAPER (rewards).
// Instead, the governance will call PAPER distributeReward method and send reward to this pool at the beginning.
contract PaperGenesisPool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. PAPER to distribute.
        uint256 lastRewardTime; // Last time that PAPER distribution occurs.
        uint256 accPaperPerShare; // Accumulated PAPER per share, times 1e18. See below.
        bool isStarted; // if lastRewardBlock has passed
    }

    IERC20 public paper;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when PAPER mining starts.
    uint256 public poolStartTime;

    // The time when PAPER mining ends.
    uint256 public poolEndTime;

    // TESTNET
    uint256 public paperPerSecond = 0.385802469 ether; // 100000 PAPER / (1h * 60min * 60s)
    uint256 public runningTime = 72 hours; // 1 hours
    uint256 public totalRewards = 10000 ether;
    // END TESTNET

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _paper,
        uint256 _poolStartTime,
        uint256 _paperPerSecond,
        uint256 _runningTime,
        uint256 _totalRewards
    ) {
        require(block.timestamp < _poolStartTime, "late");

        if (_paper != address(0)) paper = IERC20(_paper);
        
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        paperPerSecond = _paperPerSecond;
        runningTime = _runningTime;
        totalRewards = _totalRewards;

        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "PaperGenesisPool: caller is not the operator");
        _;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "PaperGenesisPool: existing pool?");
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) public onlyOperator {
        checkPoolDuplicate(_token);
        
        if (_withUpdate) {
            massUpdatePools();
        }
        
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        
        poolInfo.push(PoolInfo({
            token : _token,
            allocPoint : _allocPoint,
            lastRewardTime : _lastRewardTime,
            accPaperPerShare : 0,
            isStarted : _isStarted
            }));

        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's PAPER allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        
        PoolInfo storage pool = poolInfo[_pid];
        
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(paperPerSecond);
            return poolEndTime.sub(_fromTime).mul(paperPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(paperPerSecond);
            return _toTime.sub(_fromTime).mul(paperPerSecond);
        }
    }

    // View function to see pending PAPER on frontend.
    function pendingPAPER(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPaperPerShare = pool.accPaperPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _paperReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            
            accPaperPerShare = accPaperPerShare.add(_paperReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accPaperPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _paperReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            
            pool.accPaperPerShare = pool.accPaperPerShare.add(_paperReward.mul(1e18).div(tokenSupply));
        }
        
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        
        updatePool(_pid);
        
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accPaperPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safePaperTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        
        user.rewardDebt = user.amount.mul(pool.accPaperPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        
        require(user.amount >= _amount, "withdraw: not good");
        
        updatePool(_pid);
        
        uint256 _pending = user.amount.mul(pool.accPaperPerShare).div(1e18).sub(user.rewardDebt);
        
        if (_pending > 0) {
            safePaperTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        
        user.rewardDebt = user.amount.mul(pool.accPaperPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        
        user.amount = 0;
        user.rewardDebt = 0;
        
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe PAPER transfer function, just in case if rounding error causes pool to not have enough PAPERs.
    function safePaperTransfer(address _to, uint256 _amount) internal {
        uint256 _paperBalance = paper.balanceOf(address(this));
        
        if (_paperBalance > 0) {
            if (_amount > _paperBalance) {
                paper.safeTransfer(_to, _paperBalance);
            } else {
                paper.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.timestamp < poolEndTime + 90 days) {
            // do not allow to drain core token (PAPER or lps) if less than 90 days after pool ends
            require(_token != paper, "paper");
            
            uint256 length = poolInfo.length;
            
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}