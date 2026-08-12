/**
 * ENSv2 PermissionedRegistry event handlers for DOS Name Service.
 *
 * IMPORTANT: In ENSv2, the ERC1155 tokenId != namehash.
 * tokenId = labelhash with lower 32 bits replaced by version (LibLabel.withVersion).
 * namehash = keccak256(parentNode || labelHash).
 * We use a TokenToDomain mapping entity to resolve tokenId → domain.
 */
import {
  Address,
  BigInt,
  ByteArray,
  crypto,
  ethereum,
  store,
} from "@graphprotocol/graph-ts";

import {
  LabelRegistered as LabelRegisteredEvent,
  ResolverUpdated as ResolverUpdatedEvent,
  ExpiryUpdated as ExpiryUpdatedEvent,
  LabelUnregistered as LabelUnregisteredEvent,
  SubregistryUpdated as SubregistryUpdatedEvent,
  TokenRegenerated as TokenRegeneratedEvent,
  TransferBatch as TransferBatchEvent,
  TransferSingle as TransferSingleEvent,
} from "./types/DOSTLDRegistry/PermissionedRegistry";

import {
  Account,
  Domain,
  NewOwner,
  NewResolver,
  Registration,
  Resolver,
  ResolverSource,
  TokenToDomain,
  Transfer,
  WrappedDomain,
  WrappedTransfer,
} from "./types/schema";
import { ResolverTemplate } from "./types/templates";
import { updateSubregistry } from "./subregistry";

import {
  concat,
  createEventID,
  createOrLoadAccount,
  createOrLoadDomain,
  byteArrayFromHex,
  checkValidLabel,
  DOS_NODE,
  EMPTY_ADDRESS,
  tokenIdToHex,
} from "./utils";

var dosNode: ByteArray = byteArrayFromHex(
  DOS_NODE.slice(2) // strip 0x prefix
);

/** Resolve a tokenId to a domain node (namehash) using TokenToDomain mapping */
function resolveDomainNode(tokenId: BigInt): string | null {
  let tokenHex = tokenIdToHex(tokenId);
  let mapping = TokenToDomain.load(tokenHex);
  if (mapping !== null) {
    return mapping.domain;
  }
  return null;
}

/**
 * LabelRegistered(uint256 tokenId, bytes32 labelHash, string label, address owner, uint64 expiry, address sender)
 */
export function handleLabelRegistered(event: LabelRegisteredEvent): void {
  let label = event.params.label;
  let labelHash = event.params.labelHash;
  let owner = event.params.owner;
  let expiry = event.params.expiry;
  let tokenId = event.params.tokenId;

  if (!checkValidLabel(label)) {
    return;
  }

  // Compute the domain node (namehash) = keccak256(dosNode || labelHash)
  let node = crypto.keccak256(concat(dosNode, labelHash)).toHexString();

  // Save tokenId → domain mapping
  let tokenHex = tokenIdToHex(tokenId);
  let tokenMapping = new TokenToDomain(tokenHex);
  tokenMapping.domain = node;
  tokenMapping.save();

  // Create account
  let account = createOrLoadAccount(owner.toHexString());
  let registryAccount = createOrLoadAccount(event.address.toHexString());

  // Create or load the .dos TLD domain (parent)
  let parentDomain = createOrLoadDomain(DOS_NODE);
  if (parentDomain.name == null) {
    parentDomain.name = "dos";
    parentDomain.labelName = "dos";
    parentDomain.isMigrated = true;
    parentDomain.createdAt = event.block.timestamp;
    parentDomain.save();
  }

  // Create the domain
  let domain = Domain.load(node);
  let isNew = domain === null;
  if (domain === null) {
    domain = new Domain(node);
    domain.createdAt = event.block.timestamp;
    domain.subdomainCount = 0;
    domain.storedOffchain = false;
    domain.resolvedWithWildcard = false;
    domain.isMigrated = true;
  }

  // BENS follows the canonical ENS subgraph model for wrapped names:
  // Domain.owner is the ERC1155 wrapper/registry contract while
  // Domain.wrappedOwner and WrappedDomain.owner are the token holder.
  domain.owner = registryAccount.id;
  domain.registrant = account.id;
  domain.parent = DOS_NODE;
  domain.labelName = label;
  domain.labelhash = labelHash;
  domain.name = label + ".dos";
  domain.expiryDate = expiry;
  domain.tokenId = tokenId;
  domain.save();

  // Update parent subdomain count
  if (isNew) {
    parentDomain.subdomainCount = parentDomain.subdomainCount + 1;
    parentDomain.save();
  }

  // Create Registration entity (id = labelHash hex)
  let registration = new Registration(labelHash.toHexString());
  registration.domain = node;
  registration.registrationDate = event.block.timestamp;
  registration.expiryDate = expiry;
  registration.registrant = account.id;
  registration.labelName = label;
  registration.save();

  // Create WrappedDomain entity (ENSv2 names are always "wrapped" - ERC1155)
  let wrappedDomain = new WrappedDomain(node);
  wrappedDomain.domain = node;
  wrappedDomain.expiryDate = expiry;
  wrappedDomain.fuses = 0;
  wrappedDomain.owner = account.id;
  wrappedDomain.name = label + ".dos";
  wrappedDomain.save();

  domain.wrappedOwner = account.id;
  domain.save();

  // Create NewOwner domain event
  let domainEvent = new NewOwner(createEventID(event));
  domainEvent.blockNumber = event.block.number.toI32();
  domainEvent.transactionID = event.transaction.hash;
  domainEvent.parentDomain = DOS_NODE;
  domainEvent.domain = node;
  domainEvent.owner = account.id;
  domainEvent.save();
}

/**
 * ResolverUpdated(uint256 tokenId, address resolver, address sender)
 */
export function handleResolverUpdated(event: ResolverUpdatedEvent): void {
  let tokenId = event.params.tokenId;
  let node = resolveDomainNode(tokenId);
  if (node === null) {
    return;
  }

  let domain = Domain.load(node);
  if (domain === null) {
    return;
  }

  let resolverAddress = event.params.resolver;
  if (resolverAddress.toHexString() == EMPTY_ADDRESS) {
    domain.resolver = null;
    domain.resolvedAddress = null;
    domain.save();
    return;
  }

  let sourceId = resolverAddress.toHexString();
  let source = ResolverSource.load(sourceId);
  if (source === null) {
    source = new ResolverSource(sourceId);
    source.address = resolverAddress;
    source.save();
    ResolverTemplate.create(resolverAddress);
  }

  let resolverId = resolverAddress
    .toHexString()
    .concat("-")
    .concat(node);

  let resolver = Resolver.load(resolverId);
  if (resolver === null) {
    resolver = new Resolver(resolverId);
    resolver.domain = node;
    resolver.address = resolverAddress;
    resolver.save();
    domain.resolvedAddress = null;
  } else {
    domain.resolvedAddress = resolver.addr;
  }

  domain.resolver = resolverId;
  domain.save();

  let domainEvent = new NewResolver(createEventID(event));
  domainEvent.blockNumber = event.block.number.toI32();
  domainEvent.transactionID = event.transaction.hash;
  domainEvent.domain = node;
  domainEvent.resolver = resolverId;
  domainEvent.save();
}

/**
 * ExpiryUpdated(uint256 tokenId, uint64 newExpiry, address sender)
 */
export function handleExpiryUpdated(event: ExpiryUpdatedEvent): void {
  let tokenId = event.params.tokenId;
  let node = resolveDomainNode(tokenId);
  if (node === null) {
    return;
  }

  let newExpiry = event.params.newExpiry;
  let domain = Domain.load(node);
  if (domain === null) {
    return;
  }

  domain.expiryDate = newExpiry;
  domain.save();

  let wrappedDomain = WrappedDomain.load(node);
  if (wrappedDomain !== null) {
    wrappedDomain.expiryDate = newExpiry;
    wrappedDomain.save();
  }

  if (domain.labelhash !== null) {
    let registration = Registration.load(domain.labelhash!.toHexString());
    if (registration !== null) {
      registration.expiryDate = newExpiry;
      registration.save();
    }
  }
}

/**
 * TransferSingle(address operator, address from, address to, uint256 id, uint256 value)
 *
 * ERC1155 transfer. The `id` is the tokenId (NOT the namehash).
 * We use TokenToDomain mapping to find the correct domain.
 */
export function handleTransferSingle(event: TransferSingleEvent): void {
  if (event.params.value.equals(BigInt.fromI32(0))) {
    return;
  }

  let node = resolveDomainNode(event.params.id);
  if (node === null) {
    // No mapping found - this TransferSingle fired BEFORE LabelRegistered
    // (e.g., _mint emits TransferSingle before LabelRegistered in same tx).
    // Skip silently - LabelRegistered will set the owner.
    return;
  }

  applyOwnershipTransfer(node, event.params.to, event, "");
}

export function handleTransferBatch(event: TransferBatchEvent): void {
  let ids = event.params.ids;
  let values = event.params.values;
  let count = ids.length < values.length ? ids.length : values.length;
  for (let i = 0; i < count; i++) {
    if (values[i].equals(BigInt.fromI32(0))) {
      continue;
    }
    let node = resolveDomainNode(ids[i]);
    if (node !== null) {
      applyOwnershipTransfer(node, event.params.to, event, "-".concat(i.toString()));
    }
  }
}

function applyOwnershipTransfer(
  node: string,
  to: Address,
  event: ethereum.Event,
  eventSuffix: string
): void {
  let account = createOrLoadAccount(to.toHexString());

  let domain = Domain.load(node);
  if (domain === null) {
    return;
  }

  domain.registrant = account.id;
  domain.wrappedOwner = account.id;
  domain.save();

  // Update WrappedDomain owner
  let wrappedDomain = WrappedDomain.load(node);
  if (wrappedDomain !== null) {
    wrappedDomain.owner = account.id;
    wrappedDomain.save();
  }

  // Create Transfer event
  let transferEvent = new Transfer(createEventID(event).concat(eventSuffix));
  transferEvent.blockNumber = event.block.number.toI32();
  transferEvent.transactionID = event.transaction.hash;
  transferEvent.domain = node;
  transferEvent.owner = account.id;
  transferEvent.save();

  // Create WrappedTransfer event
  let wrappedTransfer = new WrappedTransfer(
    createEventID(event).concat("-wrapped")
      .concat(eventSuffix)
  );
  wrappedTransfer.blockNumber = event.block.number.toI32();
  wrappedTransfer.transactionID = event.transaction.hash;
  wrappedTransfer.domain = node;
  wrappedTransfer.owner = account.id;
  wrappedTransfer.save();

  // Update registration registrant
  if (domain.labelhash !== null) {
    let registration = Registration.load(domain.labelhash!.toHexString());
    if (registration !== null) {
      registration.registrant = account.id;
      registration.save();
    }
  }
}

export function handleTokenRegenerated(event: TokenRegeneratedEvent): void {
  let oldTokenHex = tokenIdToHex(event.params.oldTokenId);
  let oldMapping = TokenToDomain.load(oldTokenHex);
  if (oldMapping === null) {
    return;
  }

  let newTokenHex = tokenIdToHex(event.params.newTokenId);
  let newMapping = new TokenToDomain(newTokenHex);
  newMapping.domain = oldMapping.domain;
  newMapping.save();
  store.remove("TokenToDomain", oldTokenHex);

  let domain = Domain.load(oldMapping.domain);
  if (domain !== null) {
    domain.tokenId = event.params.newTokenId;
    domain.save();
  }
}

export function handleLabelUnregistered(event: LabelUnregisteredEvent): void {
  let tokenHex = tokenIdToHex(event.params.tokenId);
  let mapping = TokenToDomain.load(tokenHex);
  if (mapping === null) {
    return;
  }

  let domain = Domain.load(mapping.domain);
  if (domain === null) {
    store.remove("TokenToDomain", tokenHex);
    return;
  }

  updateSubregistry(mapping.domain, Address.fromString(EMPTY_ADDRESS), event, []);
  let zeroAccount = createOrLoadAccount(EMPTY_ADDRESS);
  domain.owner = zeroAccount.id;
  domain.registrant = zeroAccount.id;
  domain.wrappedOwner = zeroAccount.id;
  domain.expiryDate = event.block.timestamp;
  domain.tokenId = null;
  domain.save();

  let wrappedDomain = WrappedDomain.load(mapping.domain);
  if (wrappedDomain !== null) {
    wrappedDomain.owner = zeroAccount.id;
    wrappedDomain.expiryDate = event.block.timestamp;
    wrappedDomain.save();
  }

  if (domain.labelhash !== null) {
    let registration = Registration.load(domain.labelhash!.toHexString());
    if (registration !== null) {
      registration.registrant = zeroAccount.id;
      registration.expiryDate = event.block.timestamp;
      registration.save();
    }
  }

  store.remove("TokenToDomain", tokenHex);
}

export function handleSubregistryUpdated(event: SubregistryUpdatedEvent): void {
  let node = resolveDomainNode(event.params.tokenId);
  if (node === null || Domain.load(node) === null) {
    return;
  }
  updateSubregistry(node, event.params.subregistry, event, []);
}
