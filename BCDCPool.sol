pragma solidity 0.6.12;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./BCDC.sol";


interface IMigratorBCDCPool {
    // Perform LP token migration from legacy UniswapV2 to BCDC.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // BCDC must mint EXACTLY the same amount of BCDC LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// BCDCPool is the Bcdc. He can make Bcdc and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once BCDC is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract BCDCPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of BCDCs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accBcdcPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accBcdcPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. BCDCs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that BCDCs distribution occurs.
        uint256 accBcdcPerShare; // Accumulated BCDCs per share, times 1e12. See below.
    }

    // The BCDC TOKEN!
    BCDC public bcdc;
    // Dev address.
    address public teamAddr;
    // Block number when bonus BCDC period ends.
    uint256 public bonusEndBlock;
    // BCDC tokens created per block.
    uint256 public bcdcPerBlock;
    // Bonus muliplier for early bcdc makers.
    uint256 public constant BONUS_MULTIPLIER = 2;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorBCDCPool public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when BCDC mining starts.
    uint256 public startBlock;

    uint256 public endBlock = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        BCDC _bcdc,
        address _teamAddr,
        uint256 _bcdcPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _bonusEndBlock
    ) public {
        bcdc = _bcdc;
        teamAddr = _teamAddr;
        bcdcPerBlock = _bcdcPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;
        bonusEndBlock = _bonusEndBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accBcdcPerShare: 0
        }));
    }

    // Update the given pool's BCDC allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorBCDCPool _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    // View function to see pending BCDCs on frontend.
    function pendingBcdc(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBcdcPerShare = pool.accBcdcPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        uint256 blockNumber = 0;
        if(block.number > endBlock)
            blockNumber = endBlock;
        else
            blockNumber = block.number;
        
        if (blockNumber > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, blockNumber);
            uint256 bcdcReward = multiplier.mul(bcdcPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accBcdcPerShare = accBcdcPerShare.add(bcdcReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accBcdcPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            if (block.number > endBlock)
                pool.lastRewardBlock = endBlock;
            else
                pool.lastRewardBlock = block.number;
            return;
        }
        if (pool.lastRewardBlock == endBlock){
            return;
        }

        if (block.number > endBlock){
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, endBlock);
            uint256 bcdcReward = multiplier.mul(bcdcPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            //bcdc.mint(teamAddr, bcdcReward.div(10));
            //bcdc.mint(address(this), bcdcReward);
            pool.accBcdcPerShare = pool.accBcdcPerShare.add(bcdcReward.mul(1e12).div(lpSupply));
            pool.lastRewardBlock = endBlock;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 bcdcReward = multiplier.mul(bcdcPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        //bcdc.mint(teamAddr, bcdcReward.div(10));
        //bcdc.mint(address(this), bcdcReward);
        pool.accBcdcPerShare = pool.accBcdcPerShare.add(bcdcReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
        
    }

    // Deposit LP tokens to BCDCPool for BCDC allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accBcdcPerShare).div(1e12).sub(user.rewardDebt);
            safeBcdcTransfer(msg.sender, pending);
        }
        if(_amount > 0) { //kevin
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accBcdcPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }
    
    // DepositFor LP tokens to BCDCPool for BCDC allocation.
    function depositFor(address _beneficiary, uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_beneficiary];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accBcdcPerShare).div(1e12).sub(user.rewardDebt);
            safeBcdcTransfer(_beneficiary, pending);
        }
        if(_amount > 0) { //kevin
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accBcdcPerShare).div(1e12);
        emit Deposit(_beneficiary, _pid, _amount);
    }

    // Withdraw LP tokens from BCDCPool.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accBcdcPerShare).div(1e12).sub(user.rewardDebt);
        safeBcdcTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accBcdcPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe bcdc transfer function, just in case if rounding error causes pool to not have enough BCDCs.
    function safeBcdcTransfer(address _to, uint256 _amount) internal {
        uint256 bcdcBal = bcdc.balanceOf(address(this));
        if (_amount > bcdcBal) {
            bcdc.transfer(_to, bcdcBal);
        } else {
            bcdc.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _teamAddr) public {
        require(msg.sender == teamAddr, "dev: wut?");
        teamAddr = _teamAddr;
    }
}
