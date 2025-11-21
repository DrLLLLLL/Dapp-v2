// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
// import "@openzeppelin/contracts/utils/Counters.sol";
// Counters is no longer used to save gas

/**
 * @title Product Contract (Gas Optimized)
 * @dev Manages product lifecycle, ownership, and warranties.
 * Contains three major optimizations:
 * 1. Replaced Counters.Counter -> native uint256
 * 2. Replaced mapping(string) -> mapping(bytes32)
 * 3. Struct Field Compression (Storage Packing)
 * 4. Used Custom Errors instead of require(string) to further reduce deployment and runtime gas
 */
contract Product is ERC721, AccessControl {

    // ============================================================================
    // Error Optimization: Define Custom Errors
    // ============================================================================
    error SerialNumberEmpty(string message);
    error SerialNumberExists(string message);
    error ZeroAddress(string message);
    error NotRetailer(string message);
    error WarrantyAlreadyActivated();
    error NotOwner();
    error WarrantyNotActivated();
    error WarrantyExpired();
    error ClaimLimitReached();
    error IssueDescriptionEmpty();
    error ClaimNotExist();
    error ClaimAlreadyProcessed();
    error ClaimNotApproved();
    error ServiceAlreadyRecorded();
    error ServiceNotesEmpty();
    error ProductNotRegistered();

    // ============================================================================
    // Data Structures (Storage Compression Optimization)
    // ============================================================================
    struct ProductDetails {
        string serialNumber;
        string model;
        address manufacturer;

        // Gas Optimization Point 6: Compress time and count fields (Original 6 uint256 -> 4xuint64 + 2xuint32)
        //    Reduces storage slot usage (from 6 slots -> 2 slots), saving significant SSTORE costs
        uint64 manufactureTimestamp; // Manufacture timestamp
        uint64 warrantyDuration;     // Warranty duration (seconds)
        uint64 warrantyStart;        // Warranty start time
        uint64 warrantyExpiration;   // Warranty expiration time
        uint32 warrantyClaimLimit;   // Claim limit
        uint32 warrantyClaimCount;   // Current claim count
    }

    struct WarrantyClaim {
        uint256 tokenId;
        address customer;
        string issueDescription;
        uint64 submittedAt; // Time fields can also be compressed to uint64
        bool processed;
        bool approved;
        string serviceNotes;
        uint64 processedAt; // Same as above
    }

    // ============================================================================
    // Role Definitions
    // ============================================================================
    bytes32 public constant MANUFACTURER_ROLE = keccak256("MANUFACTURER_ROLE");
    bytes32 public constant RETAILER_ROLE = keccak256("RETAILER_ROLE");
    bytes32 public constant SERVICE_CENTER_ROLE = keccak256("SERVICE_CENTER_ROLE");

    // ============================================================================
    // State Variables
    // ============================================================================
    // Optimization Point 1: Use native uint256 instead of Counters.Counter to reduce SLOAD/SSTORE
    uint256 private _tokenIdCounter = 1;
    uint256 private _claimIdCounter = 1;

    // Optimization Point 2: Use bytes32 hash keys to reduce dynamic string hashing gas
    mapping(bytes32 => uint256) public tokenIdForSerialHash;
    // Token ID => Product Details
    mapping(uint256 => ProductDetails) public productDetails;
    // Warranty Claim ID => Claim Details
    mapping(uint256 => WarrantyClaim) public warrantyClaims;

    // ============================================================================
    // Events
    // ============================================================================
    event ProductRegistered(
        uint256 indexed tokenId,
        string serialNumber,
        string model,
        address indexed manufacturer,
        address indexed initialOwner,
        uint64 timestamp,
        uint64 warrantyDuration,
        uint32 claimLimit
    );
    event WarrantyActivated(
        uint256 indexed tokenId,
        address indexed customer,
        uint64 startTime,
        uint64 expirationTime
    );
    event WarrantyClaimSubmitted(
        uint256 indexed claimId,
        uint256 indexed tokenId,
        address indexed customer,
        string issueDescription,
        uint64 submittedAt
    );
    event WarrantyClaimProcessed(
        uint256 indexed claimId,
        uint256 indexed tokenId,
        address indexed serviceCenter,
        bool approved,
        uint64 processedAt
    );
    event ServiceRecorded(
        uint256 indexed tokenId,
        uint256 indexed claimId,
        address indexed serviceCenter,
        string serviceNotes,
        uint64 serviceDate
    );

    // ============================================================================
    // Constructor
    // ============================================================================
    constructor() ERC721("ProductProvenance", "PROD") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANUFACTURER_ROLE, msg.sender);
        _grantRole(RETAILER_ROLE, msg.sender);
        _grantRole(SERVICE_CENTER_ROLE, msg.sender);
    }

    // Resolve multiple inheritance interface conflicts
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    function test(bytes32 keyHash) public returns (bytes32 num){
        return keyHash;
    }

    // ============================================================================
    // Manufacturer Functions
    // ============================================================================
    function registerProduct(
        address initialOwner,
        string calldata serialNumber,
        string calldata model,
        uint64 warrantyDurationInSeconds,
        uint32 claimLimit
    ) external onlyRole(MANUFACTURER_ROLE) returns (uint256) {
        // Error Optimization: Use revert + Custom Error instead of require(string)
       
        if (bytes(serialNumber).length == 0) revert SerialNumberEmpty("serialnumber empty");

        // Optimization Point 3: Use bytes32 hash as key
        bytes32 serialHash = keccak256(bytes(serialNumber));
        if (tokenIdForSerialHash[serialHash] != 0) revert SerialNumberExists("serialnumber already exists");

        if (initialOwner == address(0)) revert ZeroAddress("address equals to zero");
        if (!hasRole(RETAILER_ROLE, initialOwner)) revert NotRetailer("not retailer");

        // Optimization Point 4: Use ++ directly
        uint256 newItemId = _tokenIdCounter++;
        productDetails[newItemId] = ProductDetails({
            serialNumber: serialNumber,
            model: model,
            manufacturer: msg.sender,
            manufactureTimestamp: uint64(block.timestamp),
            warrantyDuration: warrantyDurationInSeconds,
            warrantyClaimLimit: claimLimit,
            warrantyStart: 0,
            warrantyExpiration: 0,
            warrantyClaimCount: 0
        });
        tokenIdForSerialHash[serialHash] = newItemId;
        _safeMint(initialOwner, newItemId);

        emit ProductRegistered(
            newItemId,
            serialNumber,
            model,
            msg.sender,
            initialOwner,
            uint64(block.timestamp),
            warrantyDurationInSeconds,
            claimLimit
        );

        return newItemId;
    }

    // ============================================================================
    // Ownership Transfer and Automatic Warranty Activation
    // ============================================================================
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721)
        returns (address)
    {
        address from = _ownerOf(tokenId);
        address previousOwner = super._update(to, tokenId, auth);

        if (
            from != address(0) &&
            hasRole(RETAILER_ROLE, from) &&
            !hasRole(RETAILER_ROLE, to) &&
            to != address(0) &&
            productDetails[tokenId].warrantyStart == 0
        ) {
            
            _activateWarranty(tokenId, to);
        }

        return previousOwner;
    }

    function _activateWarranty(uint256 tokenId, address customer) internal {
        ProductDetails storage product = productDetails[tokenId];
        // Error Optimization
        if (product.warrantyStart != 0) revert WarrantyAlreadyActivated();

        product.warrantyStart = uint64(block.timestamp);
        product.warrantyExpiration = uint64(block.timestamp + product.warrantyDuration);

        emit WarrantyActivated(
            tokenId,
            customer,
            product.warrantyStart,
            product.warrantyExpiration
        );
    }

    // ============================================================================
    // Customer Functions
    // ============================================================================
    function submitWarrantyClaim(
        uint256 tokenId,
        string calldata issueDescription
    ) external returns (uint256) {
        // Error Optimization
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        ProductDetails storage product = productDetails[tokenId];

        if (product.warrantyStart == 0) revert WarrantyNotActivated();
        if (block.timestamp > product.warrantyExpiration) revert WarrantyExpired();
        if (product.warrantyClaimCount >= product.warrantyClaimLimit) revert ClaimLimitReached();
        if (bytes(issueDescription).length == 0) revert IssueDescriptionEmpty();

        product.warrantyClaimCount++;
        uint256 newClaimId = _claimIdCounter++;
        warrantyClaims[newClaimId] = WarrantyClaim({
            tokenId: tokenId,
            customer: _ownerOf(tokenId),
            issueDescription: issueDescription,
            submittedAt: uint64(block.timestamp),
            processed: false,
            approved: false,
            serviceNotes: "",
            processedAt: 0
        });
        emit WarrantyClaimSubmitted(
            newClaimId,
            tokenId,
            _ownerOf(tokenId),
            issueDescription,
            uint64(block.timestamp)
        );
        return newClaimId;
    }

    // ============================================================================
    // Service Center Functions
    // ============================================================================
    function processWarrantyClaim(uint256 claimId, bool approved)
        external
        onlyRole(SERVICE_CENTER_ROLE)
    {
        WarrantyClaim storage claim = warrantyClaims[claimId];
        // Error Optimization
        if (claim.tokenId == 0) revert ClaimNotExist();
        if (claim.processed) revert ClaimAlreadyProcessed();

        claim.processed = true;
        claim.approved = approved;
        claim.processedAt = uint64(block.timestamp);
        emit WarrantyClaimProcessed(
            claimId,
            claim.tokenId,
            msg.sender,
            approved,
            uint64(block.timestamp)
        );
    }

    function recordService(uint256 claimId, string calldata serviceNotes)
        external
        onlyRole(SERVICE_CENTER_ROLE)
    {
        WarrantyClaim storage claim = warrantyClaims[claimId];
        // Error Optimization
        if (claim.tokenId == 0) revert ClaimNotExist();
        if (!(claim.processed && claim.approved)) revert ClaimNotApproved();
        if (bytes(claim.serviceNotes).length != 0) revert ServiceAlreadyRecorded();
        if (bytes(serviceNotes).length == 0) revert ServiceNotesEmpty();
        claim.serviceNotes = serviceNotes;

        emit ServiceRecorded(
            claim.tokenId,
            claimId,
            msg.sender,
            serviceNotes,
            uint64(block.timestamp)
        );
    }

    // ============================================================================
    // View Functions
    // ============================================================================
    function getProductDetails(uint256 tokenId)
        external
        view
        returns (ProductDetails memory)
    {
        // Error Optimization
        if (productDetails[tokenId].manufactureTimestamp == 0) revert ProductNotRegistered();
        return productDetails[tokenId];
    }

    function getWarrantyClaim(uint256 claimId)
        external
        view
        returns (WarrantyClaim memory)
    {
        // Error Optimization
        if (warrantyClaims[claimId].tokenId == 0) revert ClaimNotExist();
        return warrantyClaims[claimId];
    }

    function isWarrantyActive(uint256 tokenId)
        external
        view
        returns (bool)
    {
        // Error Optimization
        if (productDetails[tokenId].manufactureTimestamp == 0) revert ProductNotRegistered();
        ProductDetails memory product = productDetails[tokenId];
        return
            product.warrantyStart > 0 &&
            block.timestamp <= product.warrantyExpiration &&
            product.warrantyClaimCount < product.warrantyClaimLimit;
    }
}