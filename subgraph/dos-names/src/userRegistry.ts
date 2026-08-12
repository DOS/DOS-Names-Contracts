import {
  ByteArray,
  Bytes,
  crypto,
  DataSourceContext,
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
  TransferSingle as TransferSingleEvent,
} from "./types/templates/UserRegistryTemplate/PermissionedRegistry";
import {
  Domain,
  NewResolver,
  NewOwner,
  Registration,
  RegistryPath,
  Resolver,
  ResolverSource,
  TokenToDomain,
  Transfer,
  WrappedDomain,
  WrappedTransfer,
} from "./types/schema";
import { ResolverTemplate, UserRegistryTemplate } from "./types/templates";
import {
  checkValidLabel,
  concat,
  createEventID,
  createOrLoadAccount,
  EMPTY_ADDRESS,
  tokenIdToHex,
} from "./utils";

function registryTokenId(event: ethereum.Event, tokenId: string): string {
  return event.address.toHexString().concat("-").concat(tokenId);
}

function resolveDomainNode(event: ethereum.Event, tokenId: string): string | null {
  let mapping = TokenToDomain.load(registryTokenId(event, tokenId));
  return mapping === null ? null : mapping.domain;
}

export function handleUserRegistryLabelRegistered(event: LabelRegisteredEvent): void {
  let label = event.params.label;
  if (!checkValidLabel(label)) {
    return;
  }

  let context = dataSource.context();
  let parentNode = context.getBytes("parentNode");
  let parentId = parentNode.toHexString();
  let parent = Domain.load(parentId);
  if (parent === null || parent.name === null) {
    return;
  }

  let node = crypto
    .keccak256(concat(changetype<ByteArray>(parentNode), event.params.labelHash))
    .toHexString();
  let account = createOrLoadAccount(event.params.owner.toHexString());
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

  domain.owner = account.id;
  domain.registrant = account.id;
  domain.wrappedOwner = account.id;
  domain.parent = parentId;
  domain.labelName = label;
  domain.labelhash = event.params.labelHash;
  domain.name = label.concat(".").concat(parent.name!);
  domain.expiryDate = event.params.expiry;
  domain.tokenId = event.params.tokenId;
  domain.save();

  if (isNew) {
    parent.subdomainCount = parent.subdomainCount + 1;
    parent.save();
  }

  let tokenMapping = new TokenToDomain(
    registryTokenId(event, tokenIdToHex(event.params.tokenId))
  );
  tokenMapping.domain = node;
  tokenMapping.save();

  let registration = new Registration(node);
  registration.domain = node;
  registration.registrationDate = event.block.timestamp;
  registration.expiryDate = event.params.expiry;
  registration.registrant = account.id;
  registration.labelName = label;
  registration.save();

  let wrappedDomain = new WrappedDomain(node);
  wrappedDomain.domain = node;
  wrappedDomain.expiryDate = event.params.expiry;
  wrappedDomain.fuses = 0;
  wrappedDomain.owner = account.id;
  wrappedDomain.name = domain.name;
  wrappedDomain.save();

  let domainEvent = new NewOwner(createEventID(event));
  domainEvent.blockNumber = event.block.number.toI32();
  domainEvent.transactionID = event.transaction.hash;
  domainEvent.parentDomain = parentId;
  domainEvent.domain = node;
  domainEvent.owner = account.id;
  domainEvent.save();
}

export function handleUserRegistryResolverUpdated(event: ResolverUpdatedEvent): void {
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

  let sourceId = resolverAddress.toHexString();
  let source = ResolverSource.load(sourceId);
  if (source === null) {
    source = new ResolverSource(sourceId);
    source.address = resolverAddress;
    source.save();
    ResolverTemplate.create(resolverAddress);
  }

  let resolverId = sourceId.concat("-").concat(node);
  let resolver = Resolver.load(resolverId);
  if (resolver === null) {
    resolver = new Resolver(resolverId);
    resolver.domain = node;
    resolver.address = resolverAddress;
    resolver.save();
  }

  domain.resolver = resolverId;
  domain.resolvedAddress = resolver.addr;
  domain.save();

  let domainEvent = new NewResolver(createEventID(event));
  domainEvent.domain = node;
  domainEvent.blockNumber = event.block.number.toI32();
  domainEvent.transactionID = event.transaction.hash;
  domainEvent.resolver = resolverId;
  domainEvent.save();
}

export function handleUserRegistryExpiryUpdated(event: ExpiryUpdatedEvent): void {
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
  let node = resolveDomainNode(event, tokenIdToHex(event.params.id));
  if (node === null) {
    return;
  }

  let domain = Domain.load(node);
  if (domain === null) {
    return;
  }

  let account = createOrLoadAccount(event.params.to.toHexString());
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

  let transferEvent = new Transfer(createEventID(event));
  transferEvent.domain = node;
  transferEvent.blockNumber = event.block.number.toI32();
  transferEvent.transactionID = event.transaction.hash;
  transferEvent.owner = account.id;
  transferEvent.save();

  let wrappedTransfer = new WrappedTransfer(createEventID(event).concat("-wrapped"));
  wrappedTransfer.domain = node;
  wrappedTransfer.blockNumber = event.block.number.toI32();
  wrappedTransfer.transactionID = event.transaction.hash;
  wrappedTransfer.owner = account.id;
  wrappedTransfer.save();
}

export function handleUserRegistryTokenRegenerated(event: TokenRegeneratedEvent): void {
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
  if (event.params.subregistry.toHexString() == EMPTY_ADDRESS) {
    return;
  }

  let node = resolveDomainNode(event, tokenIdToHex(event.params.tokenId));
  if (node === null || Domain.load(node) === null) {
    return;
  }

  let registryAddress = event.params.subregistry.toHexString();
  let pathId = registryAddress.concat("-").concat(node);
  let path = new RegistryPath(pathId);
  path.registry = event.params.subregistry;
  path.parentDomain = node;
  path.save();

  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(node));
  UserRegistryTemplate.createWithContext(event.params.subregistry, context);
}

export function handleUserRegistryLabelUnregistered(event: LabelUnregisteredEvent): void {
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
