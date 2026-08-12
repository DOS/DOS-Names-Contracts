import {
  Address,
  BigInt,
  ByteArray,
  Bytes,
  DataSourceContext,
  dataSource,
  ethereum,
  crypto,
  store,
} from "@graphprotocol/graph-ts";

import {
  Domain,
  NewOwner,
  Registration,
  RegistryChild,
  RegistryChildToken,
  RegistryPath,
  RegistrySource,
  Resolver,
  ResolverSource,
  TokenToDomain,
  WrappedDomain,
} from "./types/schema";
import { ResolverTemplate, UserRegistryTemplate } from "./types/templates";
import {
  concat,
  createEventID,
  createOrLoadAccount,
  EMPTY_ADDRESS,
  tokenIdToHex,
} from "./utils";

function childTokenId(registry: Address, tokenId: BigInt): string {
  return registry.toHexString().concat("-").concat(tokenIdToHex(tokenId));
}

function scopedTokenId(
  registry: Address,
  parentNode: string,
  tokenId: BigInt
): string {
  return registry
    .toHexString()
    .concat("-")
    .concat(parentNode)
    .concat("-")
    .concat(tokenIdToHex(tokenId));
}

export function isActiveUserRegistry(registry: Address): boolean {
  let parentNode = dataSource.context().getBytes("parentNode").toHexString();
  let path = RegistryPath.load(parentNode);
  return (
    path !== null &&
    path.active &&
    path.registry.toHexString() == registry.toHexString()
  );
}

export function loadRegistryChild(
  registry: Address,
  tokenId: BigInt
): RegistryChild | null {
  let token = RegistryChildToken.load(childTokenId(registry, tokenId));
  return token === null ? null : RegistryChild.load(token.child);
}

export function rememberRegistryChild(
  registry: Address,
  tokenId: BigInt,
  labelName: string,
  labelhash: Bytes,
  owner: Address,
  expiryDate: BigInt,
  createdAt: BigInt
): RegistryChild {
  let sourceId = registry.toHexString();
  let source = RegistrySource.load(sourceId);
  if (source === null) {
    source = new RegistrySource(sourceId);
    source.registry = registry;
    source.save();
  }

  let tokenKey = childTokenId(registry, tokenId);
  let token = RegistryChildToken.load(tokenKey);
  let child: RegistryChild | null = null;
  if (token !== null) {
    child = RegistryChild.load(token.child);
  }
  if (child === null) {
    child = new RegistryChild(tokenKey);
    child.source = sourceId;
    child.createdAt = createdAt;
    child.resolver = Address.fromString(EMPTY_ADDRESS);
    child.subregistry = Address.fromString(EMPTY_ADDRESS);
    child.nextChild = source.firstChild;
    source.firstChild = child.id;
    source.save();
  }

  let currentChild = child as RegistryChild;
  currentChild.tokenId = tokenId;
  currentChild.labelName = labelName;
  currentChild.labelhash = labelhash;
  currentChild.owner = owner;
  currentChild.expiryDate = expiryDate;
  currentChild.resolver = Address.fromString(EMPTY_ADDRESS);
  currentChild.subregistry = Address.fromString(EMPTY_ADDRESS);
  currentChild.active = true;
  currentChild.save();

  if (token === null) {
    token = new RegistryChildToken(tokenKey);
  }
  token.child = currentChild.id;
  token.save();
  return currentChild;
}

export function moveRegistryChildToken(
  registry: Address,
  oldTokenId: BigInt,
  newTokenId: BigInt
): RegistryChild | null {
  let oldKey = childTokenId(registry, oldTokenId);
  let oldToken = RegistryChildToken.load(oldKey);
  if (oldToken === null) {
    return null;
  }
  let child = RegistryChild.load(oldToken.child);
  if (child === null) {
    return null;
  }

  child.tokenId = newTokenId;
  child.save();
  let newToken = new RegistryChildToken(childTokenId(registry, newTokenId));
  newToken.child = child.id;
  newToken.save();
  store.remove("RegistryChildToken", oldKey);
  return child;
}

export function materializeRegistryChild(
  parentId: string,
  registry: Address,
  child: RegistryChild,
  event: ethereum.Event
): string | null {
  if (!child.active) {
    return null;
  }
  let parent = Domain.load(parentId);
  if (parent === null || parent.name === null) {
    return null;
  }

  let parentNode = Bytes.fromHexString(parentId);
  let node = crypto
    .keccak256(concat(changetype<ByteArray>(parentNode), child.labelhash))
    .toHexString();
  let account = createOrLoadAccount(child.owner.toHexString());
  let domain = Domain.load(node);
  let isNew = domain === null;
  if (domain === null) {
    domain = new Domain(node);
    domain.createdAt = child.createdAt;
    domain.subdomainCount = 0;
    domain.storedOffchain = false;
    domain.resolvedWithWildcard = false;
    domain.isMigrated = true;
  }

  domain.owner = account.id;
  domain.registrant = account.id;
  domain.wrappedOwner = account.id;
  domain.parent = parentId;
  domain.labelName = child.labelName;
  domain.labelhash = child.labelhash;
  domain.name = child.labelName.concat(".").concat(parent.name!);
  domain.expiryDate = child.expiryDate;
  domain.tokenId = child.tokenId;
  domain.save();

  if (isNew) {
    parent.subdomainCount = parent.subdomainCount + 1;
    parent.save();
  }

  let tokenMapping = new TokenToDomain(
    scopedTokenId(registry, parentId, child.tokenId)
  );
  tokenMapping.domain = node;
  tokenMapping.save();

  let registration = new Registration(node);
  registration.domain = node;
  registration.registrationDate = child.createdAt;
  registration.expiryDate = child.expiryDate;
  registration.registrant = account.id;
  registration.labelName = child.labelName;
  registration.save();

  let wrappedDomain = new WrappedDomain(node);
  wrappedDomain.domain = node;
  wrappedDomain.expiryDate = child.expiryDate;
  wrappedDomain.fuses = 0;
  wrappedDomain.owner = account.id;
  wrappedDomain.name = domain.name;
  wrappedDomain.save();

  let resolverAddress = Address.fromBytes(child.resolver);
  if (resolverAddress.toHexString() != EMPTY_ADDRESS) {
    attachResolver(domain, resolverAddress);
  }

  let domainEvent = new NewOwner(
    createEventID(event).concat("-").concat(parentId)
  );
  domainEvent.blockNumber = event.block.number.toI32();
  domainEvent.transactionID = event.transaction.hash;
  domainEvent.parentDomain = parentId;
  domainEvent.domain = node;
  domainEvent.owner = account.id;
  domainEvent.save();
  return node;
}

export function attachResolver(domain: Domain, resolverAddress: Address): void {
  let sourceId = resolverAddress.toHexString();
  let source = ResolverSource.load(sourceId);
  if (source === null) {
    source = new ResolverSource(sourceId);
    source.address = resolverAddress;
    source.save();
    ResolverTemplate.create(resolverAddress);
  }

  let resolverId = sourceId.concat("-").concat(domain.id);
  let resolver = Resolver.load(resolverId);
  if (resolver === null) {
    resolver = new Resolver(resolverId);
    resolver.domain = domain.id;
    resolver.address = resolverAddress;
    resolver.save();
  }
  domain.resolver = resolverId;
  domain.resolvedAddress = resolver.addr;
  domain.save();
}

export function updateSubregistry(
  parentNode: string,
  registry: Address,
  event: ethereum.Event
): void {
  let path = RegistryPath.load(parentNode);
  let registryAddress = registry.toHexString();

  if (registryAddress == EMPTY_ADDRESS) {
    if (path !== null) {
      path.active = false;
      path.save();
    }
    return;
  }

  let requiresSource =
    path === null || path.registry.toHexString() != registryAddress;
  if (path === null) {
    path = new RegistryPath(parentNode);
    path.parentDomain = parentNode;
  }
  path.registry = registry;
  path.active = true;
  path.save();

  if (requiresSource) {
    let context = new DataSourceContext();
    context.setBytes("parentNode", Bytes.fromHexString(parentNode));
    UserRegistryTemplate.createWithContext(registry, context);
  }

  let source = RegistrySource.load(registryAddress);
  let childId: string | null = null;
  if (source !== null) {
    childId = source.firstChild;
  }
  while (childId !== null) {
    let currentId = childId as string;
    let child = RegistryChild.load(currentId);
    if (child === null) {
      break;
    }
    let node = materializeRegistryChild(parentNode, registry, child, event);
    if (
      node !== null &&
      child.subregistry.toHexString() != EMPTY_ADDRESS
    ) {
      updateSubregistry(node as string, Address.fromBytes(child.subregistry), event);
    }
    childId = child.nextChild;
  }
}
