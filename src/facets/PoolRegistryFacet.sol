// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {ILiquidityAdapter} from "../interfaces/ILiquidityAdapter.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title PoolRegistryFacet
 * @author Yield Forge Team
 * @notice Manages pool registration, guardian roles, and protocol configuration
 * @dev Replaces PoolFactoryFacet with multi-protocol support
 *
 * ARCHITECTURE OVERVIEW:
 * ----------------------
 * This facet handles:
 * 1. Pool Registration - Register existing pools for yield tokenization
 * 2. Adapter Management - Approve/revoke liquidity adapters
 * 3. Pool Guardian - Ban/unban pools for emergency control
 * 4. QuoteToken Whitelist - Approve tokens for secondary market pricing
 * 5. Fee Configuration - Set protocol fee recipient
 *
 * KEY DIFFERENCES FROM PoolFactoryFacet:
 * - Doesn't CREATE pools, only REGISTERS existing ones
 * - Works with any supported protocol via adapters
 * - Adds guardian role for emergency pool control
 * - Adds adapter approval system
 *
 * POOL REGISTRATION FLOW:
 * -----------------------
 * 1. Owner approves an adapter (e.g., UniswapV4Adapter)
 * 2. Anyone calls registerPool(adapter, poolParams)
 * 3. Adapter validates poolParams and extracts tokens
 * 4. Pool is registered with unique poolId
 * 5. Pool is ready for first addLiquidity (which starts cycle 1)
 * 6. Banned pools cannot be re-registered
 *
 * POOL ID GENERATION:
 * -------------------
 * poolId = keccak256(abi.encode(adapter, poolParams))
 *
 * This ensures uniqueness across:
 * - Different protocols (same pool can't be registered twice)
 * - Different pools within same protocol
 *
 * ACCESS CONTROL:
 * ---------------
 * - Owner: Adapter approval, guardian management, quoteTokens, fees
 * - Anyone: Pool registration (with approved adapters)
 * - PoolGuardian: Can only ban/unban pools (for quick emergency response)
 * - Banned pools: Cannot be re-registered by anyone
 *
 * SECURITY NOTES:
 * ---------------
 * - Only approved adapters can be used
 * - Adapter must validate poolParams before registration
 * - Banned pools cannot receive new liquidity
 * - Existing positions can still be redeemed from banned pools
 */
contract PoolRegistryFacet {
    // ============================================================
    //                          EVENTS
    // ============================================================

    /// @notice Emitted when protocol is initialized
    event ProtocolInitialized(address indexed feeRecipient);

    /// @notice Emitted when a new pool is registered
    /// @dev externalPoolId is keccak256(poolParams) - matches PoolId for linking to external UIs
    event PoolRegistered(
        bytes32 indexed poolId,
        address indexed adapter,
        address token0,
        address token1,
        address quoteToken,
        bytes32 externalPoolId
    );

    /// @notice Emitted when an adapter is approved or revoked
    event AdapterStatusChanged(address indexed adapter, bool approved);

    /// @notice Emitted when pool guardian is set
    event PoolGuardianSet(
        address indexed oldGuardian,
        address indexed newGuardian
    );

    /// @notice Emitted when a pool is banned
    event PoolBanned(bytes32 indexed poolId, address indexed guardian);

    /// @notice Emitted when a pool is unbanned
    event PoolUnbanned(bytes32 indexed poolId, address indexed guardian);

    /// @notice Emitted when protocol fee recipient is updated
    event FeeRecipientSet(
        address indexed oldRecipient,
        address indexed newRecipient
    );

    /// @notice Emitted when a quote token is approved or revoked
    event QuoteTokenStatusChanged(address indexed token, bool approved);

    /// @notice Emitted when a pool's quote token is changed
    event PoolQuoteTokenChanged(
        bytes32 indexed poolId,
        address indexed oldQuoteToken,
        address indexed newQuoteToken
    );

    // Note: ProtocolFeeSet event removed.
    // Fees are now constants in ProtocolFees.sol library.

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Protocol already initialized
    error AlreadyInitialized();

    /// @notice Protocol not yet initialized
    error NotInitialized();

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Adapter not approved
    error AdapterNotApproved(address adapter);

    /// @notice Adapter already approved
    error AdapterAlreadyApproved(address adapter);

    /// @notice Adapter not currently approved
    error AdapterNotCurrentlyApproved(address adapter);

    /// @notice Pool already exists
    error PoolAlreadyExists(bytes32 poolId);

    /// @notice Pool does not exist
    error PoolNotFound(bytes32 poolId);

    /// @notice Pool is already banned
    error PoolAlreadyBanned(bytes32 poolId);

    /// @notice Pool is not currently banned
    error PoolNotBanned(bytes32 poolId);

    /// @notice Caller is not pool guardian
    error NotPoolGuardian();

    /// @notice Pool not supported by adapter
    error PoolNotSupported();

    /// @notice Invalid recipient (e.g., Diamond address)
    error InvalidRecipient(address recipient);

    /// @notice No approved quote token found in pool
    /// @dev At least one of pool's tokens must be in the whitelist
    error NoApprovedQuoteToken();

    /// @notice Invalid quote token (not one of pool's tokens)
    error InvalidQuoteToken(address token);

    /// @notice Quote token already approved
    error QuoteTokenAlreadyApproved(address token);

    /// @notice Quote token not currently approved
    error QuoteTokenNotApproved(address token);

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    // Note: Protocol fees are defined in ProtocolFees.sol
    // - No mint fee (users receive 100% of PT/YT)
    // - 5% yield fee (taken from harvested yield)

    // ============================================================
    //                        MODIFIERS
    // ============================================================

    /// @notice Restrict to contract owner
    modifier onlyOwner() {
        LibDiamond.enforceIsContractOwner();
        _;
    }

    /// @notice Restrict to pool guardian or owner
    modifier onlyPoolGuardian() {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        if (
            msg.sender != s.poolGuardian &&
            msg.sender != LibDiamond.contractOwner()
        ) {
            revert NotPoolGuardian();
        }
        _;
    }

    /// @notice Ensure protocol is initialized
    modifier whenInitialized() {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.initialized) {
            revert NotInitialized();
        }
        _;
    }

    // ============================================================
    //                     INITIALIZATION
    // ============================================================

    /**
     * @notice Initialize the protocol
     * @dev Can only be called once by owner
     *
     * Sets up:
     * - Protocol fee recipient (treasury address)
     *
     * @param feeRecipient_ Address to receive protocol fees
     *
     * Example:
     *   registry.initialize(treasury);
     */
    function initialize(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        if (s.initialized) {
            revert AlreadyInitialized();
        }

        s.initialized = true;
        s.protocolFeeRecipient = feeRecipient_;

        emit ProtocolInitialized(feeRecipient_);
    }

    /**
     * @notice Check if protocol is initialized
     * @return True if initialized
     */
    function isInitialized() external view returns (bool) {
        return LibAppStorage.diamondStorage().initialized;
    }

    // ============================================================
    //                   ADAPTER MANAGEMENT
    // ============================================================

    /**
     * @notice Approve an adapter for pool registration
     * @dev Only approved adapters can be used to register pools
     *
     * SECURITY: Carefully audit adapters before approval!
     * Malicious adapters could steal funds.
     *
     * @param adapter Address of the liquidity adapter
     *
     * Example:
     *   registry.approveAdapter(uniswapV4Adapter);
     *   registry.approveAdapter(curveAdapter);
     */
    function approveAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.approvedAdapters[adapter]) {
            revert AdapterAlreadyApproved(adapter);
        }
        s.approvedAdapters[adapter] = true;

        emit AdapterStatusChanged(adapter, true);
    }

    /**
     * @notice Revoke an adapter's approval
     * @dev Existing pools using this adapter continue to work
     *      but no new pools can be registered with it
     *
     * @param adapter Address of the adapter to revoke
     */
    function revokeAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.approvedAdapters[adapter]) {
            revert AdapterNotCurrentlyApproved(adapter);
        }
        s.approvedAdapters[adapter] = false;

        emit AdapterStatusChanged(adapter, false);
    }

    /**
     * @notice Check if adapter is approved
     * @param adapter Address to check
     * @return True if approved
     */
    function isAdapterApproved(address adapter) external view returns (bool) {
        return LibAppStorage.diamondStorage().approvedAdapters[adapter];
    }

    // ============================================================
    //                  QUOTE TOKEN MANAGEMENT
    // ============================================================

    /**
     * @notice Approve a token for use as quote currency in secondary markets
     * @dev Only approved tokens can be used as quoteToken for pools
     *
     * RECOMMENDED WHITELIST:
     * - USDC  (most stable, preferred)
     * - WETH  (for ETH-paired pools)
     * - DAI   (stable alternative)
     *
     * At least one of a pool's tokens must be in the whitelist
     * for the pool to be registered.
     *
     * @param token Address of the token to approve
     *
     * Example:
     *   registry.approveQuoteToken(USDC);
     *   registry.approveQuoteToken(WETH);
     */
    function approveQuoteToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.approvedQuoteTokens[token]) {
            revert QuoteTokenAlreadyApproved(token);
        }
        s.approvedQuoteTokens[token] = true;

        emit QuoteTokenStatusChanged(token, true);
    }

    /**
     * @notice Revoke a token's approval as quote currency
     * @dev Existing pools using this token continue to work
     *      but no new pools can use it as quoteToken
     *
     * @param token Address of the token to revoke
     */
    function revokeQuoteToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.approvedQuoteTokens[token]) {
            revert QuoteTokenNotApproved(token);
        }
        s.approvedQuoteTokens[token] = false;

        emit QuoteTokenStatusChanged(token, false);
    }

    /**
     * @notice Check if a token is approved as quote currency
     * @param token Address to check
     * @return True if approved
     */
    function isQuoteTokenApproved(address token) external view returns (bool) {
        return LibAppStorage.diamondStorage().approvedQuoteTokens[token];
    }

    // ============================================================
    //                   POOL REGISTRATION
    // ============================================================

    /**
     * @notice Register an existing pool for yield tokenization
     * @dev Creates a new pool entry in the registry
     *
     * FLOW:
     * 1. Validate adapter is approved
     * 2. Validate pool is supported by adapter
     * 3. Validate quoteToken is valid (in pool + whitelisted)
     * 4. Generate unique poolId
     * 5. Extract token addresses from adapter
     * 6. Store pool info
     *
     * NOTE: This does NOT create PT/YT tokens. Those are created
     * on first addLiquidity() call (see LiquidityFacet).
     *
     * @param adapter Address of the liquidity adapter to use
     * @param poolParams Protocol-specific pool parameters (encoded)
     * @param quoteToken Token to use as quote currency (must be in pool + whitelisted)
     * @return poolId Unique identifier for the registered pool
     *
     * PARAMS ENCODING BY ADAPTER:
     * - UniswapV4Adapter: abi.encode(PoolKey)
     * - UniswapV3Adapter: abi.encode(poolAddress)
     * - CurveAdapter: abi.encode(curvePool, gauge)
     *
     * Example:
     *   // Register a Uniswap V4 pool with USDT as quote
     *   PoolKey memory key = PoolKey({...});
     *   bytes32 poolId = registry.registerPool(
     *       v4Adapter,
     *       abi.encode(key),
     *       USDT
     *   );
     */
    function registerPool(
        address adapter,
        bytes calldata poolParams,
        address quoteToken
    ) external whenInitialized returns (bytes32 poolId) {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        // Verify adapter is approved
        if (!s.approvedAdapters[adapter]) {
            revert AdapterNotApproved(adapter);
        }

        // Verify pool is supported by adapter
        ILiquidityAdapter adapterContract = ILiquidityAdapter(adapter);
        if (!adapterContract.supportsPool(poolParams)) {
            revert PoolNotSupported();
        }

        // Generate unique pool ID
        poolId = keccak256(abi.encode(adapter, poolParams));

        // Check pool doesn't already exist
        if (s.pools[poolId].exists) {
            revert PoolAlreadyExists(poolId);
        }

        // Get token addresses from adapter
        (address token0, address token1) = adapterContract.getPoolTokens(
            poolParams
        );

        // Validate quoteToken is one of the pool's tokens
        if (quoteToken != token0 && quoteToken != token1) {
            revert InvalidQuoteToken(quoteToken);
        }

        // Validate quoteToken is in the whitelist
        if (!s.approvedQuoteTokens[quoteToken]) {
            revert QuoteTokenNotApproved(quoteToken);
        }

        // Get quoteToken decimals for AMM calculations
        // Cached here to save gas on every swap operation
        uint8 quoteDecimals = IERC20Metadata(quoteToken).decimals();

        // Store pool info
        s.pools[poolId] = LibAppStorage.PoolInfo({
            adapter: adapter,
            poolParams: poolParams,
            token0: token0,
            token1: token1,
            exists: true,
            isBanned: false,
            quoteToken: quoteToken,
            quoteDecimals: quoteDecimals
        });

        // externalPoolId = keccak256(poolParams) - matches Uniswap V4 PoolId format
        // Used for external links (e.g., Uniswap explore page)
        bytes32 externalPoolId = keccak256(poolParams);
        emit PoolRegistered(
            poolId,
            adapter,
            token0,
            token1,
            quoteToken,
            externalPoolId
        );
    }

    // ============================================================
    //                   POOL GUARDIAN
    // ============================================================

    /**
     * @notice Set the pool guardian address
     * @dev Guardian can ban/unban pools without owner approval
     *      This allows quick response to security issues
     *
     * @param guardian Address of the new guardian (can be address(0) to remove)
     */
    function setPoolGuardian(address guardian) external onlyOwner {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        address oldGuardian = s.poolGuardian;
        s.poolGuardian = guardian;

        emit PoolGuardianSet(oldGuardian, guardian);
    }

    /**
     * @notice Get current pool guardian
     * @return Guardian address
     */
    function poolGuardian() external view returns (address) {
        return LibAppStorage.diamondStorage().poolGuardian;
    }

    /**
     * @notice Ban a pool from receiving new liquidity
     * @dev Can be called by guardian or owner
     *
     * EFFECTS:
     * - addLiquidity() will revert for this pool
     * - Existing positions can still be redeemed
     * - Yield can still be claimed
     * - New cycles cannot be started
     *
     * USE CASES:
     * - Security vulnerability in underlying pool
     * - Suspicious activity detected
     * - Protocol deprecation
     *
     * @param poolId Pool to ban
     */
    function banPool(bytes32 poolId) external onlyPoolGuardian {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolNotFound(poolId);
        }
        if (pool.isBanned) {
            revert PoolAlreadyBanned(poolId);
        }

        pool.isBanned = true;

        emit PoolBanned(poolId, msg.sender);
    }

    /**
     * @notice Unban a pool, allowing new liquidity
     * @dev Can be called by guardian or owner
     *
     * @param poolId Pool to unban
     */
    function unbanPool(bytes32 poolId) external onlyPoolGuardian {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolNotFound(poolId);
        }
        if (!pool.isBanned) {
            revert PoolNotBanned(poolId);
        }

        pool.isBanned = false;

        emit PoolUnbanned(poolId, msg.sender);
    }

    /**
     * @notice Check if a pool is banned
     * @param poolId Pool to check
     * @return True if banned
     */
    function isPoolBanned(bytes32 poolId) external view returns (bool) {
        return LibAppStorage.diamondStorage().pools[poolId].isBanned;
    }

    /**
     * @notice Change the quote token for a pool
     * @dev New quote token must be one of the pool's tokens and approved
     *
     * USE CASES:
     * - Original quote token depegged
     * - Change pricing strategy
     *
     * @param poolId Pool identifier
     * @param newQuoteToken New quote token address
     */
    function setPoolQuoteToken(
        bytes32 poolId,
        address newQuoteToken
    ) external onlyOwner {
        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();
        LibAppStorage.PoolInfo storage pool = s.pools[poolId];

        if (!pool.exists) {
            revert PoolNotFound(poolId);
        }

        // Must be one of the pool's tokens
        if (newQuoteToken != pool.token0 && newQuoteToken != pool.token1) {
            revert InvalidQuoteToken(newQuoteToken);
        }

        // Must be an approved quote token
        if (!s.approvedQuoteTokens[newQuoteToken]) {
            revert QuoteTokenNotApproved(newQuoteToken);
        }

        address oldQuoteToken = pool.quoteToken;
        pool.quoteToken = newQuoteToken;

        emit PoolQuoteTokenChanged(poolId, oldQuoteToken, newQuoteToken);
    }

    // ============================================================
    //                    FEE CONFIGURATION
    // ============================================================

    /**
     * @notice Set protocol fee recipient
     * @dev Address that receives protocol fees from minting and yield
     *
     * @param recipient New fee recipient
     */
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this)) revert InvalidRecipient(recipient);

        LibAppStorage.AppStorage storage s = LibAppStorage.diamondStorage();

        address oldRecipient = s.protocolFeeRecipient;
        s.protocolFeeRecipient = recipient;

        emit FeeRecipientSet(oldRecipient, recipient);
    }

    /**
     * @notice Get current fee recipient
     * @return Fee recipient address
     */
    function feeRecipient() external view returns (address) {
        return LibAppStorage.diamondStorage().protocolFeeRecipient;
    }

    // Note: protocolFeeBps() function removed.
    // Fees are now in ProtocolFees.sol library.

    // ============================================================
    //                     VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get pool information
     * @param poolId Pool identifier
     * @return info Pool information struct
     */
    function getPoolInfo(
        bytes32 poolId
    ) external view returns (LibAppStorage.PoolInfo memory info) {
        return LibAppStorage.diamondStorage().pools[poolId];
    }

    /**
     * @notice Check if pool exists
     * @param poolId Pool identifier
     * @return True if pool is registered
     */
    function poolExists(bytes32 poolId) external view returns (bool) {
        return LibAppStorage.diamondStorage().pools[poolId].exists;
    }

    /**
     * @notice Get current cycle ID for a pool
     * @dev Returns 0 if no cycle has started yet
     *
     * @param poolId Pool identifier
     * @return Current cycle ID
     */
    function getCurrentCycleId(bytes32 poolId) external view returns (uint256) {
        return LibAppStorage.diamondStorage().currentCycleId[poolId];
    }

    /**
     * @notice Get cycle information
     * @param poolId Pool identifier
     * @param cycleId Cycle number
     * @return info Cycle information struct
     */
    function getCycleInfo(
        bytes32 poolId,
        uint256 cycleId
    ) external view returns (LibAppStorage.CycleInfo memory info) {
        return LibAppStorage.diamondStorage().cycles[poolId][cycleId];
    }

    /**
     * @notice Get current active PT token for a pool
     * @dev Returns address(0) if no cycle has started
     *
     * @param poolId Pool identifier
     * @return PT token address
     */
    function getActivePT(bytes32 poolId) external view returns (address) {
        return LibAppStorage.diamondStorage().activePT[poolId];
    }

    /**
     * @notice Get current active YT token for a pool
     * @dev Returns address(0) if no cycle has started
     *
     * @param poolId Pool identifier
     * @return YT token address
     */
    function getActiveYT(bytes32 poolId) external view returns (address) {
        return LibAppStorage.diamondStorage().activeYT[poolId];
    }

    /**
     * @notice Get pool tokens
     * @param poolId Pool identifier
     * @return token0 First token
     * @return token1 Second token
     */
    function getPoolTokens(
        bytes32 poolId
    ) external view returns (address token0, address token1) {
        LibAppStorage.PoolInfo storage pool = LibAppStorage
            .diamondStorage()
            .pools[poolId];
        return (pool.token0, pool.token1);
    }

    /**
     * @notice Get pool adapter
     * @param poolId Pool identifier
     * @return Adapter address
     */
    function getPoolAdapter(bytes32 poolId) external view returns (address) {
        return LibAppStorage.diamondStorage().pools[poolId].adapter;
    }
}
