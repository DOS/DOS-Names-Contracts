import {
  Address,
  BigInt,
  dataSource,
  ethereum,
  store,
} from "@graphprotocol/graph-ts";

import {
  ExpiryUpdated as ExpiryUpdatedEvent,
  LabelUnregistered as LabelUnregisteredEvent,
  LabelRegistered as LabelRegisteredEvent,
  ResolverUpdated as ResolverUpdatedEvent,
  SubregistryUpdated as SubregistryUpdatedEvent,
  TokenRegenerated as TokenRegeneratedEvent,
  TransferBatch as TransferBatchEvent,
  TransferSingle as TransferSingleEvent,
} from "./types/templates/UserRegistryTemplate/PermissionedRegistry";
import {
  Domain,
  NewResolver,
  Registration,
  TokenToDomain,
  Transfer,
  WrappedDomain,
  WrappedTransfer,
} from "./types/schema";
import {
  activeRegistryAncestors,
  attachResolver,
  isActiveUserRegistry,
  loadRegistryChild,
  materializeRegistryChild,
  moveRegistryChildToken,
  rememberRegistryChild,
  updateSubregistry,
} from "./subregistry";
import {
  checkValidLabel,
  createEventID,
  createOrLoadAccount,
  EMPTY_ADDRESS,
  tokenIdToHex,
} from "./utils";

function registryTokenId(event: ethereum.Event, tokenId: string): string {
  return event.address
    .toHexString()
    .concat("-")
    .concat(dataSource.context().getBytes("parentNode").toHexString())
    .concat("-")
    .concat(tokenId);
}

function resolveDomainNode(event: ethereum.Event, tokenId: string): string | null {
  let mapping = TokenToDomain.load(registryTokenId(event, tokenId));
  return mapping === null ? null : mapping.domain;
}

function contextEventID(event: ethereum.Event): string {
  return createEventID(event)
    .concat("-")
    .concat(dataSource.context().getBytes("parentNode").toHexString());
}

export function handleUserRegistryLabelRegistered(event: LabelRegisteredEvent): void {
  let label = event.params.label;
  if (!checkValidLabel(label)) {
    return;
  }
  let child = rememberRegistryChild(
    event.address,
    event.params.tokenId,
    label,
    event.params.labelHash,
    event.params.owner,
    event.params.expiry,
    event.block.timestamp
  );
  let registryAncestors = activeRegistryAncestors(event.address);
  if (registryAncestors === null) {
    return;
  }
  materializeRegistryChild(
    dataSource.context().getBytes("parentNode").toHexString(),
    event.address,
    child,
    event
  );
}

export function handleUserRegistryResolverUpdated(event: ResolverUpdatedEvent): void {
  let child = loadRegistryChild(event.address, event.params.tokenId);
  if (child === null) {
    return;
  }
  child.resolver = event.params.resolver;
  child.save();
  if (!isActiveUserRegistry(event.address)) {
    return;
  }
  let node = resolveDomainNode(event, tokenIdToHex(event.params.tokenId));
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

  attachResolver(domain, resolverAddress);
  let resolverId = resolverAddress.toHexString().concat("-").concat(node);

  let domainEvent = new NewResolver(contextEventID(event));
  domainEvent.domain = node;
  domainEvent.blockNumber = event.block.number.toI32();
  domainEvent.transactionID = event.transaction.hash;
  domainEvent.resolver = resolverId;
  domainEvent.save();
}

export function handleUserRegistryExpiryUpdated(event: ExpiryUpdatedEvent): void {
  let child = loadRegistryChild(event.address, event.params.tokenId);
  if (child !== null) {
    child.expiryDate = event.params.newExpiry;
    child.save();
  }
  if (!isActiveUserRegistry(event.address)) {
    return;
  }
  let node = resolveDomainNode(event, tokenIdToHex(event.params.tokenId));
  if (node === null) {
    return;
  }

  let domain = Domain.load(node);
  if (domain !== null) {
    domain.expiryDate = event.params.newExpiry;
    domain.save();
  }

  let wrappedDomain = WrappedDomain.load(node);
  if (wrappedDomain !== null) {
    wrappedDomain.expiryDate = event.params.newExpiry;
    wrappedDomain.save();
  }

  let registration = Registration.load(node);
  if (registration !== null) {
    registration.expiryDate = event.params.newExpiry;
    registration.save();
  }
}

export function handleUserRegistryTransferSingle(event: TransferSingleEvent): void {
  if (event.params.value.equals(BigInt.fromI32(0))) {
    return;
  }
  let child = loadRegistryChild(event.address, event.params.id);
  if (child !== null) {
    child.owner = event.params.to;
    child.save();
  }
  if (!isActiveUserRegistry(event.address)) {
    return;
  }
  let node = resolveDomainNode(event, tokenIdToHex(event.params.id));
  if (node === null) {
    return;
  }

  let domain = Domain.load(node);
  if (domain === null) {
    return;
  }

  applyOwnershipTransfer(node, event.params.to, event, "");
}

export function handleUserRegistryTransferBatch(event: TransferBatchEvent): void {
  let active = isActiveUserRegistry(event.address);
  let ids = event.params.ids;
  let values = event.params.values;
  let count = ids.length < values.length ? ids.length : values.length;
  for (let i = 0; i < count; i++) {
    if (values[i].equals(BigInt.fromI32(0))) {
      continue;
    }
    let child = loadRegistryChild(event.address, ids[i]);
    if (child !== null) {
      child.owner = event.params.to;
      child.save();
    }
    if (!active) {
      continue;
    }
    let node = resolveDomainNode(event, tokenIdToHex(ids[i]));
    if (node !== null) {
      applyOwnershipTransfer(
        node,
        event.params.to,
        event,
        "-".concat(i.toString())
      );
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
  domain.owner = account.id;
  domain.registrant = account.id;
  domain.wrappedOwner = account.id;
  domain.save();

  let wrappedDomain = WrappedDomain.load(node);
  if (wrappedDomain !== null) {
    wrappedDomain.owner = account.id;
    wrappedDomain.save();
  }

  let registration = Registration.load(node);
  if (registration !== null) {
    registration.registrant = account.id;
    registration.save();
  }

  let transferEvent = new Transfer(contextEventID(event).concat(eventSuffix));
  transferEvent.domain = node;
  transferEvent.blockNumber = event.block.number.toI32();
  transferEvent.transactionID = event.transaction.hash;
  transferEvent.owner = account.id;
  transferEvent.save();

  let wrappedTransfer = new WrappedTransfer(
    contextEventID(event).concat("-wrapped").concat(eventSuffix)
  );
  wrappedTransfer.domain = node;
  wrappedTransfer.blockNumber = event.block.number.toI32();
  wrappedTransfer.transactionID = event.transaction.hash;
  wrappedTransfer.owner = account.id;
  wrappedTransfer.save();
}

export function handleUserRegistryTokenRegenerated(event: TokenRegeneratedEvent): void {
  moveRegistryChildToken(
    event.address,
    event.params.oldTokenId,
    event.params.newTokenId
  );
  if (!isActiveUserRegistry(event.address)) {
    return;
  }
  let oldId = registryTokenId(event, tokenIdToHex(event.params.oldTokenId));
  let oldMapping = TokenToDomain.load(oldId);
  if (oldMapping === null) {
    return;
  }

  let newId = registryTokenId(event, tokenIdToHex(event.params.newTokenId));
  let newMapping = new TokenToDomain(newId);
  newMapping.domain = oldMapping.domain;
  newMapping.save();
  store.remove("TokenToDomain", oldId);

  let domain = Domain.load(oldMapping.domain);
  if (domain !== null) {
    domain.tokenId = event.params.newTokenId;
    domain.save();
  }
}

export function handleUserRegistrySubregistryUpdated(event: SubregistryUpdatedEvent): void {
  let child = loadRegistryChild(event.address, event.params.tokenId);
  if (child !== null) {
    child.subregistry = event.params.subregistry;
    child.save();
  }
  let registryAncestors = activeRegistryAncestors(event.address);
  if (registryAncestors === null) {
    return;
  }

  let node = resolveDomainNode(event, tokenIdToHex(event.params.tokenId));
  if (node === null || Domain.load(node) === null) {
    return;
  }

  updateSubregistry(
    node,
    event.params.subregistry,
    event,
    registryAncestors as string[]
  );
}

export function handleUserRegistryLabelUnregistered(event: LabelUnregisteredEvent): void {
  let child = loadRegistryChild(event.address, event.params.tokenId);
  if (child !== null) {
    child.active = false;
    child.expiryDate = event.block.timestamp;
    child.owner = Address.fromString(EMPTY_ADDRESS);
    child.save();
  }
  let registryAncestors = activeRegistryAncestors(event.address);
  if (registryAncestors === null) {
    return;
  }
  let tokenKey = registryTokenId(event, tokenIdToHex(event.params.tokenId));
  let mapping = TokenToDomain.load(tokenKey);
  if (mapping === null) {
    return;
  }

  let domain = Domain.load(mapping.domain);
  if (domain === null) {
    store.remove("TokenToDomain", tokenKey);
    return;
  }

  updateSubregistry(
    mapping.domain,
    Address.fromString(EMPTY_ADDRESS),
    event,
    registryAncestors as string[]
  );
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

  let registration = Registration.load(mapping.domain);
  if (registration !== null) {
    registration.registrant = zeroAccount.id;
    registration.expiryDate = event.block.timestamp;
    registration.save();
  }

  store.remove("TokenToDomain", tokenKey);
}
