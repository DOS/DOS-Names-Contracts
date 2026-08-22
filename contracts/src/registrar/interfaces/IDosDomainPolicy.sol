// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IETHRegistrar} from "./IETHRegistrar.sol";

/// @dev Interface selector: `0xb291e5bf`
interface IDosDomainPolicy {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice Operation authorized by a DOS.Me voucher.
    enum Operation {
        CLAIM,
        RENEW,
        RECLAIM
    }

    /// @notice Signed authorization for one policy operation.
    struct Voucher {
        Operation operation;
        address wallet;
        bytes32 accountId;
        bytes32 labelhash;
        uint64 duration;
        IERC20 paymentToken;
        uint256 maxPrice;
        uint256 nonce;
        uint64 deadline;
    }

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice The policy registrar was configured.
    /// @param registrar The configured registrar.
    event RegistrarSet(IETHRegistrar indexed registrar);

    /// @notice The voucher signer was updated.
    /// @param signer The new voucher signer.
    event VoucherSignerSet(address indexed signer);

    /// @notice The DOS.Me score threshold was updated.
    /// @param minimumScore The required score in DOS.Me score units.
    event MinimumScoreSet(uint32 minimumScore);

    /// @notice A claim or reclaim commitment was recorded.
    /// @param commitment The registrar commitment.
    /// @param labelhash The claimed label hash.
    /// @param wallet The authorized DOS Wallet.
    /// @param nonce The voucher nonce.
    event ClaimCommitted(
        bytes32 indexed commitment,
        bytes32 indexed labelhash,
        address indexed wallet,
        uint256 nonce
    );

    /// @notice An initial free DOS ID domain was registered.
    /// @param tokenId The registry token ID.
    /// @param labelhash The registered label hash.
    /// @param label The registered label.
    /// @param wallet The DOS Wallet that owns the name.
    /// @param paidExpiry The on-chain expiry after registration.
    /// @param paymentToken The registrar payment token.
    /// @param paidPrice The subsidy amount paid by this policy.
    event DosDomainClaimed(
        uint256 indexed tokenId,
        bytes32 indexed labelhash,
        string label,
        address wallet,
        uint64 paidExpiry,
        IERC20 paymentToken,
        uint256 paidPrice
    );

    /// @notice A DOS ID domain was renewed.
    /// @param tokenId The registry token ID.
    /// @param labelhash The renewed label hash.
    /// @param label The renewed label.
    /// @param wallet The DOS Wallet that owns the name.
    /// @param paidExpiry The on-chain expiry after renewal.
    /// @param paymentToken The registrar payment token.
    /// @param paidPrice The amount paid by the wallet.
    event DosDomainRenewed(
        uint256 indexed tokenId,
        bytes32 indexed labelhash,
        string label,
        address wallet,
        uint64 paidExpiry,
        IERC20 paymentToken,
        uint256 paidPrice
    );

    /// @notice A historically claimed DOS ID domain was registered again for a fee.
    /// @param tokenId The registry token ID.
    /// @param labelhash The reclaimed label hash.
    /// @param label The reclaimed label.
    /// @param wallet The DOS Wallet that owns the name.
    /// @param paidExpiry The on-chain expiry after registration.
    /// @param paymentToken The registrar payment token.
    /// @param paidPrice The amount paid by the wallet.
    event DosDomainReclaimed(
        uint256 indexed tokenId,
        bytes32 indexed labelhash,
        string label,
        address wallet,
        uint64 paidExpiry,
        IERC20 paymentToken,
        uint256 paidPrice
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x0a9644cf`
    error InvalidLabel(string label);
    /// @dev Error selector: `0x6d67dbd6`
    error InvalidVoucher();
    /// @dev Error selector: `0x68641fc4`
    error VoucherExpired(uint64 deadline);
    /// @dev Error selector: `0x91cab504`
    error NonceAlreadyUsed(uint256 nonce);
    /// @dev Error selector: `0xb9137cf5`
    error WrongWallet(address caller, address wallet);
    /// @dev Error selector: `0x7ee36f10`
    error InvalidOperation(Operation expected, Operation actual);
    /// @dev Error selector: `0xc138385a`
    error InitialClaimDurationInvalid(uint64 duration);
    /// @dev Error selector: `0xecf304be`
    error FirstClaimAlreadyUsed(address wallet);
    /// @dev Error selector: `0xa12ff4c4`
    error AccountAlreadyClaimed(bytes32 accountId);
    /// @dev Error selector: `0x8c961146`
    error LabelAlreadyClaimed(bytes32 labelhash);
    /// @dev Error selector: `0x70fef996`
    error LabelNotPreviouslyClaimed(bytes32 labelhash);
    /// @dev Error selector: `0x477707e8`
    error NameNotAvailable(string label);
    /// @dev Error selector: `0x9e6a3193`
    error NotCurrentOwner(address expected, address actual);
    /// @dev Error selector: `0xeb491a07`
    error RenewalGracePeriodEnded(bytes32 labelhash);
    /// @dev Error selector: `0xe352f6db`
    error PriceExceedsVoucher(uint256 actualPrice, uint256 maxPrice);
    /// @dev Error selector: `0xf94a80d9`
    error RegistrarAlreadySet();
    /// @dev Error selector: `0xe4cea3b4`
    error RegistrarNotSet();
    /// @dev Error selector: `0xfe4404fb`
    error InvalidRegistrationController(address actual);
    /// @dev Error selector: `0xd92e233d`
    error ZeroAddress();

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Configures the one policy-controlled registrar.
    /// @param registrar_ The registrar whose controller is this policy.
    function setRegistrar(IETHRegistrar registrar_) external;

    /// @notice Records an initial-claim commitment.
    /// @param label The label to claim.
    /// @param voucher The authorization voucher.
    /// @param signature The voucher signature.
    /// @param secret The commitment secret.
    function commitClaim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external;

    /// @notice Records a paid-reclaim commitment.
    /// @param label The label to reclaim.
    /// @param voucher The authorization voucher.
    /// @param signature The voucher signature.
    /// @param secret The commitment secret.
    function commitReclaim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external;

    /// @notice Registers the wallet's first free DOS ID domain.
    /// @param label The label to claim.
    /// @param voucher The authorization voucher.
    /// @param signature The voucher signature.
    /// @param secret The commitment secret.
    /// @return tokenId The registered registry token ID.
    function claim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external
        returns (uint256 tokenId);

    /// @notice Renews a qualifying wallet's domain during the grace window.
    /// @param label The label to renew.
    /// @param voucher The authorization voucher.
    /// @param signature The voucher signature.
    function renew(string calldata label, Voucher calldata voucher, bytes calldata signature)
        external;

    /// @notice Registers a previously claimed label again for a fee.
    /// @param label The label to reclaim.
    /// @param voucher The authorization voucher.
    /// @param signature The voucher signature.
    /// @param secret The commitment secret.
    /// @return tokenId The registered registry token ID.
    function reclaim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external
        returns (uint256 tokenId);

    /// @notice Hashes a voucher using the policy EIP-712 domain.
    /// @param voucher The voucher to hash.
    /// @return The EIP-712 digest.
    function hashVoucher(Voucher memory voucher) external view returns (bytes32);

    /// @notice Reports whether the label was registered before or through this policy.
    /// @param labelhash The label hash to check.
    /// @return `true` if the registry or policy records a prior registration.
    function hasHistoricalClaim(bytes32 labelhash) external view returns (bool);

    /// @notice Reports whether the wallet can renew the name during its grace window.
    /// @param label The label to check.
    /// @param wallet The current DOS Wallet owner.
    /// @return `true` if the wallet owns a renewable name.
    function isRenewalEligible(string calldata label, address wallet) external view returns (bool);

    /// @notice Reports whether a historical name is currently available for paid reclaim.
    /// @param label The label to check.
    /// @return `true` if the name has history and can be registered again.
    function isReclaimEligible(string calldata label) external view returns (bool);

    /// @notice Quotes the registrar cost for a policy operation.
    /// @param operation The intended operation.
    /// @param label The label to price.
    /// @param duration The requested duration in seconds.
    /// @param paymentToken The registrar payment token.
    /// @return base The base registration or renewal price.
    /// @return premium The registration premium, if applicable.
    /// @return total The total amount to pay.
    function quote(Operation operation, string calldata label, uint64 duration, IERC20 paymentToken)
        external
        view
        returns (uint256 base, uint256 premium, uint256 total);

    /// @notice Reports whether the wallet currently holds an active policy claim.
    /// @param label The label to check.
    /// @param wallet The DOS Wallet to check.
    /// @return `true` if the wallet owns the name before its grace period ends.
    function isDosMeEntitled(string calldata label, address wallet) external view returns (bool);
}
