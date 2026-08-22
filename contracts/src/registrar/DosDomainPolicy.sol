// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {IDosDomainPolicy} from "./interfaces/IDosDomainPolicy.sol";
import {IETHRegistrar} from "./interfaces/IETHRegistrar.sol";

/// @dev Interface selector: `0x210b5bd2`
interface IDOSPolicyRegistrar is IETHRegistrar {
    /// @notice Returns the only contract permitted to register and renew names.
    function REGISTRATION_CONTROLLER() external view returns (address);
}


/// @notice Score-gated controller for DOS ID `.dos` registrations.
/// @dev DOS.Me verifies identity, wallet binding, and score off-chain, then issues a short-lived
///      EIP-712 voucher. This contract enforces voucher validity, lifecycle invariants, and the
///      non-bypass path into the ENSv2 registrar.
contract DosDomainPolicy is IDosDomainPolicy, EIP712, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Free initial claim duration, in seconds.
    uint64 public constant INITIAL_CLAIM_DURATION = 365 days;

    /// @notice Post-expiry renewal window, in seconds.
    uint64 public constant GRACE_PERIOD = 28 days;

    /// @dev EIP-712 type hash for policy vouchers.
    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256(
            "Voucher(uint8 operation,address wallet,bytes32 accountId,bytes32 labelhash,uint64 duration,address paymentToken,uint256 maxPrice,uint256 nonce,uint64 deadline)"
        );

    /// @notice Registry that owns `.dos` name state.
    IPermissionedRegistry public immutable REGISTRY;

    /// @notice Resolver applied to policy-created names.
    address public immutable DEFAULT_RESOLVER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Registrar restricted to this policy controller.
    IETHRegistrar public registrar;

    /// @notice Signer authorized to issue DOS.Me vouchers.
    address public voucherSigner;

    /// @notice Minimum DOS.Me score included in eligibility checks.
    uint32 public minimumScore;

    /// @notice Whether a voucher nonce has been consumed.
    mapping(uint256 nonce => bool used) public usedNonces;

    /// @notice Whether a label has ever completed an initial claim.
    mapping(bytes32 labelhash => bool claimed) public labelEverClaimed;

    /// @notice Whether a wallet has completed its one free initial claim.
    mapping(address wallet => bool claimed) public walletEverClaimed;

    /// @notice Whether a DOS.Me account has completed its one free initial claim.
    mapping(bytes32 accountId => bool claimed) public accountEverClaimed;

    /// @notice Registry expiry recorded after each successful policy operation.
    mapping(bytes32 labelhash => uint64 expiry) public paidExpiry;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param registry The `.dos` registry.
    /// @param initialOwner The policy administrator.
    /// @param initialVoucherSigner The initial DOS.Me voucher signer.
    /// @param initialMinimumScore The initial DOS.Me eligibility threshold.
    /// @param defaultResolver The resolver applied to policy-created names.
    constructor(
        IPermissionedRegistry registry,
        address initialOwner,
        address initialVoucherSigner,
        uint32 initialMinimumScore,
        address defaultResolver
    )
        EIP712("DOS Domain Policy", "1")
        Ownable(initialOwner)
    {
        if (address(registry) == address(0) || initialVoucherSigner == address(0)) {
            revert ZeroAddress();
        }

        REGISTRY = registry;
        DEFAULT_RESOLVER = defaultResolver;
        voucherSigner = initialVoucherSigner;
        minimumScore = initialMinimumScore;

        emit VoucherSignerSet(initialVoucherSigner);
        emit MinimumScoreSet(initialMinimumScore);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IDosDomainPolicy
    function setRegistrar(IETHRegistrar registrar_) external override onlyOwner {
        if (address(registrar) != address(0)) {
            revert RegistrarAlreadySet();
        }
        if (address(registrar_) == address(0)) {
            revert ZeroAddress();
        }
        address controller = IDOSPolicyRegistrar(address(registrar_)).REGISTRATION_CONTROLLER();
        if (controller != address(this)) {
            revert InvalidRegistrationController(controller);
        }

        registrar = registrar_;
        emit RegistrarSet(registrar_);
    }

    /// @notice Changes the signer allowed to authorize policy operations.
    /// @param newVoucherSigner The new voucher signer.
    function setVoucherSigner(address newVoucherSigner) external onlyOwner {
        if (newVoucherSigner == address(0)) {
            revert ZeroAddress();
        }

        voucherSigner = newVoucherSigner;
        emit VoucherSignerSet(newVoucherSigner);
    }

    /// @notice Changes the score that DOS.Me must enforce before issuing a voucher.
    /// @param newMinimumScore The new minimum score in DOS.Me score units.
    function setMinimumScore(uint32 newMinimumScore) external onlyOwner {
        minimumScore = newMinimumScore;
        emit MinimumScoreSet(newMinimumScore);
    }

    /// @notice Pauses all voucher-consuming operations.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Restores voucher-consuming operations.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Withdraws policy subsidy funds.
    /// @param token The token to withdraw.
    /// @param recipient The recipient of the withdrawn tokens.
    /// @param amount The amount to withdraw.
    function withdrawToken(IERC20 token, address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        token.safeTransfer(recipient, amount);
    }

    /// @inheritdoc IDosDomainPolicy
    function commitClaim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external
        override
        whenNotPaused
    {
        _validateVoucher(label, voucher, signature, Operation.CLAIM);
        _validateInitialClaim(label, voucher);
        _commit(label, voucher, secret);
    }

    /// @inheritdoc IDosDomainPolicy
    function commitReclaim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external
        override
        whenNotPaused
    {
        _validateVoucher(label, voucher, signature, Operation.RECLAIM);
        _validateReclaim(label, voucher);
        _commit(label, voucher, secret);
    }

    /// @inheritdoc IDosDomainPolicy
    function claim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        _validateVoucher(label, voucher, signature, Operation.CLAIM);
        _validateInitialClaim(label, voucher);

        uint256 price = _priceAndCheckCap(label, voucher);
        _approveRegistrar(voucher.paymentToken, price);
        tokenId = _register(label, voucher, secret);

        usedNonces[voucher.nonce] = true;
        labelEverClaimed[voucher.labelhash] = true;
        walletEverClaimed[voucher.wallet] = true;
        accountEverClaimed[voucher.accountId] = true;
        uint64 expiry = uint64(block.timestamp) + voucher.duration;
        paidExpiry[voucher.labelhash] = expiry;

        emit DosDomainClaimed(
            tokenId,
            voucher.labelhash,
            label,
            voucher.wallet,
            expiry,
            voucher.paymentToken,
            price
        );
    }

    /// @inheritdoc IDosDomainPolicy
    function renew(string calldata label, Voucher calldata voucher, bytes calldata signature)
        external
        override
        whenNotPaused
        nonReentrant
    {
        _validateVoucher(label, voucher, signature, Operation.RENEW);
        _requireRegistrar();

        IPermissionedRegistry.State memory state = REGISTRY.getState(LibLabel.id(label));
        if (state.latestOwner != voucher.wallet) {
            revert NotCurrentOwner(voucher.wallet, state.latestOwner);
        }
        uint64 currentExpiry = state.expiry;
        if (currentExpiry == 0 || block.timestamp >= uint256(currentExpiry) + GRACE_PERIOD) {
            revert RenewalGracePeriodEnded(voucher.labelhash);
        }

        uint256 price = _priceAndCheckCap(label, voucher);
        voucher.paymentToken.safeTransferFrom(_msgSender(), address(this), price);
        _approveRegistrar(voucher.paymentToken, price);
        registrar.renew(label, voucher.duration, voucher.paymentToken, bytes32(0));

        usedNonces[voucher.nonce] = true;
        labelEverClaimed[voucher.labelhash] = true;
        accountEverClaimed[voucher.accountId] = true;
        uint64 expiry = currentExpiry + voucher.duration;
        paidExpiry[voucher.labelhash] = expiry;

        emit DosDomainRenewed(
            state.tokenId,
            voucher.labelhash,
            label,
            voucher.wallet,
            expiry,
            voucher.paymentToken,
            price
        );
    }

    /// @inheritdoc IDosDomainPolicy
    function reclaim(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        bytes32 secret
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        _validateVoucher(label, voucher, signature, Operation.RECLAIM);
        _validateReclaim(label, voucher);

        uint256 price = _priceAndCheckCap(label, voucher);
        voucher.paymentToken.safeTransferFrom(_msgSender(), address(this), price);
        _approveRegistrar(voucher.paymentToken, price);
        tokenId = _register(label, voucher, secret);

        usedNonces[voucher.nonce] = true;
        labelEverClaimed[voucher.labelhash] = true;
        accountEverClaimed[voucher.accountId] = true;
        uint64 expiry = uint64(block.timestamp) + voucher.duration;
        paidExpiry[voucher.labelhash] = expiry;

        emit DosDomainReclaimed(
            tokenId,
            voucher.labelhash,
            label,
            voucher.wallet,
            expiry,
            voucher.paymentToken,
            price
        );
    }

    /// @inheritdoc IDosDomainPolicy
    function isDosMeEntitled(string calldata label, address wallet)
        external
        view
        override
        returns (bool)
    {
        bytes32 labelhash = keccak256(bytes(label));
        uint64 expiry = paidExpiry[labelhash];
        if (expiry == 0 || block.timestamp >= uint256(expiry) + GRACE_PERIOD) {
            return false;
        }

        IPermissionedRegistry.State memory state = REGISTRY.getState(LibLabel.id(label));
        return state.latestOwner == wallet;
    }

    /// @inheritdoc IDosDomainPolicy
    function hashVoucher(Voucher memory voucher) public view override returns (bytes32) {
        return _hashTypedDataV4(_voucherStructHash(voucher));
    }

    /// @inheritdoc IDosDomainPolicy
    function hasHistoricalClaim(bytes32 labelhash) public view override returns (bool) {
        return labelEverClaimed[labelhash] || REGISTRY.getState(uint256(labelhash)).expiry != 0;
    }

    /// @inheritdoc IDosDomainPolicy
    function isRenewalEligible(string calldata label, address wallet)
        public
        view
        override
        returns (bool)
    {
        IPermissionedRegistry.State memory state = REGISTRY.getState(LibLabel.id(label));
        return
            state.latestOwner == wallet &&
            state.expiry != 0 &&
            block.timestamp < uint256(state.expiry) + GRACE_PERIOD;
    }

    /// @inheritdoc IDosDomainPolicy
    function isReclaimEligible(string calldata label) public view override returns (bool) {
        return
            address(registrar) != address(0) &&
            hasHistoricalClaim(keccak256(bytes(label))) &&
            registrar.isAvailable(label);
    }

    /// @inheritdoc IDosDomainPolicy
    function quote(Operation operation, string calldata label, uint64 duration, IERC20 paymentToken)
        public
        view
        override
        returns (uint256 base, uint256 premium, uint256 total)
    {
        _requireRegistrar();
        if (operation == Operation.RENEW) {
            base = registrar.getRenewPrice(label, duration, paymentToken);
        } else {
            (base, premium) = registrar.getRegisterPrice(label, duration, paymentToken);
        }
        total = base + premium;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Sets the registrar allowance to the current payment amount.
    function _approveRegistrar(IERC20 token, uint256 amount) internal {
        token.forceApprove(address(registrar), amount);
    }

    /// @dev Creates a commitment unless an unexpired identical commitment already exists.
    function _commit(string calldata label, Voucher calldata voucher, bytes32 secret) internal {
        _requireRegistrar();
        bytes32 commitment =
            registrar.makeCommitment(
                label,
                voucher.wallet,
                secret,
                IRegistry(address(0)),
                DEFAULT_RESOLVER,
                voucher.duration,
                bytes32(0)
            );
        uint64 committedAt = registrar.commitmentAt(commitment);
        if (
            committedAt == 0 ||
            block.timestamp >= uint256(committedAt) + registrar.MAX_COMMITMENT_AGE()
        ) {
            registrar.commit(commitment);
        }
        emit ClaimCommitted(commitment, voucher.labelhash, voucher.wallet, voucher.nonce);
    }

    /// @dev Registers through the policy-controlled registrar using voucher parameters.
    function _register(string calldata label, Voucher calldata voucher, bytes32 secret)
        internal
        returns (uint256)
    {
        return
            registrar.register(
                label,
                voucher.wallet,
                secret,
                IRegistry(address(0)),
                DEFAULT_RESOLVER,
                voucher.duration,
                voucher.paymentToken,
                bytes32(0)
            );
    }

    /// @dev Validates that the wallet, operation, expiry, nonce, label, and signature match a voucher.
    function _validateVoucher(
        string calldata label,
        Voucher calldata voucher,
        bytes calldata signature,
        Operation expectedOperation
    )
        internal
        view
    {
        _validateLabel(label);
        if (_msgSender() != voucher.wallet) {
            revert WrongWallet(_msgSender(), voucher.wallet);
        }
        if (voucher.operation != expectedOperation) {
            revert InvalidOperation(expectedOperation, voucher.operation);
        }
        if (voucher.accountId == bytes32(0)) {
            revert InvalidVoucher();
        }
        if (voucher.deadline < block.timestamp) {
            revert VoucherExpired(voucher.deadline);
        }
        if (usedNonces[voucher.nonce]) {
            revert NonceAlreadyUsed(voucher.nonce);
        }
        if (voucher.labelhash != keccak256(bytes(label))) {
            revert InvalidVoucher();
        }
        if (!SignatureChecker.isValidSignatureNow(voucherSigner, hashVoucher(voucher), signature)) {
            revert InvalidVoucher();
        }
    }

    /// @dev Validates free-claim duration, per-wallet and per-label history, and registrar availability.
    function _validateInitialClaim(string calldata label, Voucher calldata voucher) internal view {
        _requireRegistrar();
        if (voucher.duration != INITIAL_CLAIM_DURATION) {
            revert InitialClaimDurationInvalid(voucher.duration);
        }
        if (walletEverClaimed[voucher.wallet]) {
            revert FirstClaimAlreadyUsed(voucher.wallet);
        }
        if (accountEverClaimed[voucher.accountId]) {
            revert AccountAlreadyClaimed(voucher.accountId);
        }
        if (hasHistoricalClaim(voucher.labelhash)) {
            revert LabelAlreadyClaimed(voucher.labelhash);
        }
        if (!registrar.isAvailable(label)) {
            revert NameNotAvailable(label);
        }
    }

    /// @dev Validates historical claim status and current registrar availability for a paid reclaim.
    function _validateReclaim(string calldata label, Voucher calldata voucher) internal view {
        _requireRegistrar();
        if (!hasHistoricalClaim(voucher.labelhash)) {
            revert LabelNotPreviouslyClaimed(voucher.labelhash);
        }
        if (!registrar.isAvailable(label)) {
            revert NameNotAvailable(label);
        }
    }

    /// @dev Returns the current registrar price only when it does not exceed the signed cap.
    function _priceAndCheckCap(string calldata label, Voucher calldata voucher)
        internal
        view
        returns (uint256 price)
    {
        (, , price) = quote(voucher.operation, label, voucher.duration, voucher.paymentToken);
        if (price > voucher.maxPrice) {
            revert PriceExceedsVoucher(price, voucher.maxPrice);
        }
    }

    /// @dev Reverts while no registrar has been bound to the policy.
    function _requireRegistrar() internal view {
        if (address(registrar) == address(0)) {
            revert RegistrarNotSet();
        }
    }

    /// @dev Produces the EIP-712 struct hash before the domain separator is applied.
    function _voucherStructHash(Voucher memory voucher) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH,
                    voucher.operation,
                    voucher.wallet,
                    voucher.accountId,
                    voucher.labelhash,
                    voucher.duration,
                    voucher.paymentToken,
                    voucher.maxPrice,
                    voucher.nonce,
                    voucher.deadline
                )
            );
    }

    /// @dev Enforces the lower-case DOS ID label grammar.
    function _validateLabel(string calldata label) internal pure {
        bytes calldata value = bytes(label);
        uint256 length = value.length;
        if (length < 5 || length > 63) {
            revert InvalidLabel(label);
        }
        if (!_isAlphaNumeric(value[0]) || !_isAlphaNumeric(value[length - 1])) {
            revert InvalidLabel(label);
        }

        for (uint256 i; i < length; ++i) {
            bytes1 character = value[i];
            if (character != "-" && !_isAlphaNumeric(character)) {
                revert InvalidLabel(label);
            }
        }
    }

    /// @dev Reports whether one byte is an ASCII lower-case letter or digit.
    function _isAlphaNumeric(bytes1 character) internal pure returns (bool) {
        return (character >= "a" && character <= "z") || (character >= "0" && character <= "9");
    }
}
