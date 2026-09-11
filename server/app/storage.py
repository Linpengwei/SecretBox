from __future__ import annotations

class StorageCatalog:
    def ensure_structures(self) -> list[str]:
        return ["sqlite:provider_configs", "sqlite:vault_records"]


storage_catalog = StorageCatalog()
