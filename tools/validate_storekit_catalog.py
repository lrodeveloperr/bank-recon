#!/usr/bin/env python3
"""Fail closed if the local StoreKit catalogue drifts from the release contract."""

from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path


CATALOG = Path("App/StoreKit/BankReconciliation.storekit")
EXPECTED = {
    "com.worksbienstudios.bankreconciliation.pro": Decimal("39.99"),
    "com.worksbienstudios.bankreconciliation.accountant": Decimal("99.99"),
}
LOCALES = {"en_US", "fr_FR", "es_ES", "de_DE", "pt_BR"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"StoreKit catalogue invalid: {message}")


def main() -> None:
    payload = json.loads(CATALOG.read_text(encoding="utf-8"))
    products = payload.get("products")
    require(isinstance(products, list), "products must be an array")
    require(len(products) == len(EXPECTED), "exactly two products are required")

    by_id = {product.get("productID"): product for product in products}
    require(set(by_id) == set(EXPECTED), "product identifiers do not match the release contract")
    require(len({product.get("internalID") for product in products}) == len(products), "internal IDs must be unique")
    require(payload.get("settings") == {}, "catalogue must be local, not App Store Connect-synced")

    for product_id, expected_price in EXPECTED.items():
        product = by_id[product_id]
        require(product.get("type") == "NonConsumable", f"{product_id} must be non-consumable")
        require(Decimal(product.get("displayPrice", "")) == expected_price, f"{product_id} price drifted")
        localizations = product.get("localizations")
        require(isinstance(localizations, list), f"{product_id} localizations must be an array")
        require({item.get("locale") for item in localizations} == LOCALES, f"{product_id} locale set drifted")
        for item in localizations:
            require(bool(item.get("displayName")), f"{product_id} has an empty localized name")
            require(bool(item.get("description")), f"{product_id} has an empty localized description")

    print("StoreKit catalogue: 2 non-consumables, prices and 5 locales verified")


if __name__ == "__main__":
    main()
