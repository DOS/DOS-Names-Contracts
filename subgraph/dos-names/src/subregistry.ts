import {
  Address,
  Bytes,
  DataSourceContext,
  dataSource,
} from "@graphprotocol/graph-ts";

import { RegistryPath } from "./types/schema";
import { UserRegistryTemplate } from "./types/templates";
import { EMPTY_ADDRESS } from "./utils";

export function isActiveUserRegistry(registry: Address): boolean {
  let parentNode = dataSource.context().getBytes("parentNode").toHexString();
  let path = RegistryPath.load(parentNode);
  return (
    path !== null &&
    path.active &&
    path.registry.toHexString() == registry.toHexString()
  );
}

export function updateSubregistry(
  parentNode: string,
  registry: Address
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
}
